#!/bin/sh
# Memory comparison, old vs new release, same workload, under the unit's heap cap.
# Runs INSIDE the cv-smoke-caddy container. Never touches CT109.
#   smoke3.sh <new.tar.gz> <old.tar.gz>
set -u
W=/work; PORT=3111
mkdir -p "$W/new" "$W/old" "$W/managed" "$W/log"
: > "$W/managed/sites.caddy"; : > "$W/log/access.log"
head -c 24 /dev/urandom | base64 > "$W/pw"
tar -xzf "/in/$1" -C "$W/new"; tar -xzf "/in/$2" -C "$W/old"
NEW="$(find "$W/new" -mindepth 1 -maxdepth 1 -type d | head -1)"
OLD="$(find "$W/old" -mindepth 1 -maxdepth 1 -type d | head -1)"

cat > "$W/Caddyfile" <<'EOF'
{
	admin unix//work/admin.sock|0222
	local_certs
}
(access_log) {
	log {
		output file /work/log/access.log {
			mode 644
		}
		format json
	}
}
*.smoke.test {
	import access_log
	tls internal
	@app host app.smoke.test
	handle @app {
		respond "app" 200
	}
	handle {
		respond "fallback" 200
	}
}
import /work/managed/sites.caddy
EOF
caddy run --config "$W/Caddyfile" --adapter caddyfile > "$W/caddy.log" 2>&1 &
CADDY_PID=$!
i=0; while [ ! -S "$W/admin.sock" ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done

export NODE_ENV=production HOSTNAME=127.0.0.1 PORT=$PORT NEXT_TELEMETRY_DISABLED=1 TZ=UTC
export ADMIN_USERNAME=smoketest ADMIN_INITIAL_PASSWORD_FILE="$W/pw" ALLOW_INSECURE_LAN_HTTP=false
export CADDY_ADMIN_URL=unix:///work/admin.sock CADDY_MAIN_CADDYFILE="$W/Caddyfile"
export CADDY_MANAGED_DIR="$W/managed" CADDY_ACCESS_LOG_FILE="$W/log/access.log"
# Same as the systemd unit in the kit:
export NODE_OPTIONS=--max-old-space-size=192
unset AUTH_DISABLED CERT_CHECK_PRIVATE_DOMAINS BIND_ADDRESS

mem() { grep -E 'VmHWM|VmRSS' "/proc/$1/status" | tr -s ' \t' ' ' | tr '\n' ' '; echo; }

run_one() { # <label> <release-dir> <pages>
  label="$1"; rel="$2"; pages="$3"
  export DATABASE_PATH="$W/data-$label.db"
  rm -f "$DATABASE_PATH" "$DATABASE_PATH-wal" "$DATABASE_PATH-shm"
  ( cd "$rel/app" && exec "$rel/bin/node" server.js >"$W/$label.log" 2>&1 ) &
  pid=$!
  i=0; while [ $i -lt 40 ]; do
    "$rel/bin/node" -e "fetch('http://127.0.0.1:$PORT/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" 2>/dev/null && break
    i=$((i+1)); sleep 1
  done
  printf '\n== %s (%s): idle after start: ' "$label" "$(cat "$rel/VERSION")"; mem "$pid"
  "$rel/bin/node" /scripts/traffic.mjs > /dev/null
  for pass in 1 2 3; do
    PAGES="$pages" "$rel/bin/node" /scripts/authed.mjs "http://127.0.0.1:$PORT" smoketest "$W/pw" | grep -E 'FAIL|PASSED|FAILED' | tr '\n' ' '
    printf '\n   after page pass %s: ' "$pass"; mem "$pid"
  done
  sleep 15
  printf '   after 15 s idle: '; mem "$pid"
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

OLD_PAGES="/dashboard,/metrics,/logs,/config,/config/caddyfile,/config/new,/settings"
NEW_PAGES="/dashboard,/metrics,/logs,/config,/config/caddyfile,/config/new,/certificates,/settings"
run_one old "$OLD" "$OLD_PAGES"
run_one new "$NEW" "$NEW_PAGES"
kill -TERM "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID" 2>/dev/null
echo; echo "done"
