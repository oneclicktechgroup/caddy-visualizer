#!/bin/sh
# Runs INSIDE the cv-smoke-caddy container (Debian 13 + Caddy 2.11.4 binary). Never touches CT109.
#   smoke2.sh <new-release.tar.gz>
set -u
NEW_TGZ="/in/$1"
W=/work
PORT=3111
FAILS=0
say()  { printf '\n===== %s =====\n' "$*"; }
note() { printf '%s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$W/new" "$W/managed" "$W/log" "$W/data"
: > "$W/managed/sites.caddy"; : > "$W/log/access.log"
head -c 24 /dev/urandom | base64 > "$W/pw"
tar -xzf "$NEW_TGZ" -C "$W/new"
NEW="$(find "$W/new" -mindepth 1 -maxdepth 1 -type d | head -1)"
say "versions"; cat "$NEW/VERSION"; "$NEW/bin/node" -v; caddy version

# Same shape as the live setup: global options with the admin socket, access-log snippet,
# one wildcard site with @name host + handle blocks, and the managed-sites import.
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

say "start caddy"
caddy run --config "$W/Caddyfile" --adapter caddyfile > "$W/caddy.log" 2>&1 &
CADDY_PID=$!
i=0; while [ ! -S "$W/admin.sock" ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done
[ -S "$W/admin.sock" ] && ls -l "$W/admin.sock" || bad "admin socket did not appear"

export NODE_ENV=production HOSTNAME=127.0.0.1 PORT=$PORT NEXT_TELEMETRY_DISABLED=1 TZ=UTC
export ADMIN_USERNAME=smoketest ADMIN_INITIAL_PASSWORD_FILE="$W/pw" ALLOW_INSECURE_LAN_HTTP=false
export CADDY_ADMIN_URL=unix:///work/admin.sock CADDY_MAIN_CADDYFILE="$W/Caddyfile"
export CADDY_MANAGED_DIR="$W/managed" CADDY_ACCESS_LOG_FILE="$W/log/access.log" DATABASE_PATH="$W/data/t.db"
unset AUTH_DISABLED CERT_CHECK_PRIVATE_DOMAINS BIND_ADDRESS

PID=""
start_app() { ( cd "$NEW/app" && exec "$NEW/bin/node" server.js >"$1" 2>&1 ) & PID=$!; }
wait_health() {
  i=0
  while [ $i -lt 40 ]; do
    "$NEW/bin/node" -e "fetch('http://127.0.0.1:$PORT/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" 2>/dev/null && return 0
    kill -0 "$PID" 2>/dev/null || return 1
    i=$((i+1)); sleep 1
  done; return 1
}
stop_app() { kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; note "app exit status: $?"; }
sql() { ( cd "$NEW/app" && "$NEW/bin/node" -e "const D=require('better-sqlite3');const db=new D('$DATABASE_PATH',{readonly:true});$1" ); }

say "PHASE 1: wildcard-only Caddyfile (the live shape)"
start_app "$W/app1.log"
wait_health && note "app healthy" || bad "app not healthy"

say "traffic through Caddy"
"$NEW/bin/node" /scripts/traffic.mjs

say "authenticated page checks"
"$NEW/bin/node" /scripts/authed.mjs "http://127.0.0.1:$PORT" smoketest "$W/pw" || bad "authed checks failed"

say "waiting 75 s for the first scheduled certificate check (60 s after start) and the access-log reader"
sleep 75
say "phase 1 app log"; cat "$W/app1.log"
grep -q '\[certificates\] checked 0 host names' "$W/app1.log" && note "RESULT: wildcard-only config -> 0 hosts probed" || bad "expected '[certificates] checked 0 host names'"
grep -q '\[access-log\].*: ok' "$W/app1.log" && note "RESULT: access log read ok" || bad "access log not read ok"
note "-- db after phase 1:"
sql "console.log('certificate_checks rows:', db.prepare('select count(*) c from certificate_checks').get().c);
     console.log('access_log_entries rows:', db.prepare('select count(*) c from access_log_entries').get().c);
     console.log('hosts seen:', db.prepare('select host, count(*) n from access_log_entries group by host').all().map(r=>r.host+'='+r.n).join(', '));"
note "-- memory:"; grep -E 'VmHWM|VmRSS' "/proc/$PID/status" | tr -s ' \t' ' '
stop_app

say "PHASE 2: add two named sites; names resolved through /etc/hosts to loopback and a private address"
cat >> /etc/hosts <<'EOF'
127.0.0.1 forbidden.smoke.test
10.255.255.1 private.smoke.test
EOF
cat >> "$W/Caddyfile" <<'EOF'

forbidden.smoke.test {
	tls internal
	respond "f" 200
}
private.smoke.test {
	tls internal
	respond "p" 200
}
EOF
caddy reload --config "$W/Caddyfile" --adapter caddyfile --address unix//work/admin.sock --force > "$W/reload.log" 2>&1 && note "caddy reload ok" || { bad "caddy reload failed"; cat "$W/reload.log"; }
sleep 2
start_app "$W/app2.log"
wait_health && note "app healthy" || bad "app not healthy"
say "waiting 75 s for the first scheduled certificate check"
sleep 75
say "phase 2 app log"; cat "$W/app2.log"
grep -q '\[certificates\] checked 2 host names' "$W/app2.log" && note "RESULT: 2 named hosts checked (wildcard still skipped)" || bad "expected '[certificates] checked 2 host names'"
sql "for (const r of db.prepare('select hostname, outcome, error, address from certificate_checks order by hostname').all()) console.log(JSON.stringify(r));"
stop_app

kill -TERM "$CADDY_PID" 2>/dev/null; wait "$CADDY_PID" 2>/dev/null
say "caddy log (tail)"; tail -n 15 "$W/caddy.log"
say "SUMMARY"
if [ "$FAILS" -eq 0 ]; then echo "SMOKE2: no failures"; else echo "SMOKE2: $FAILS failure(s)"; fi
exit "$FAILS"
