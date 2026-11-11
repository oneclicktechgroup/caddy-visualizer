#!/bin/sh
# Runs INSIDE a Debian 13 container (same glibc as CT109). Never touches CT109.
#   smoke.sh <new-release.tar.gz> [<old-release.tar.gz>]
# Tarballs are read from /in (mounted read-only), scripts from /scripts.
set -u

NEW_TGZ="/in/$1"
OLD_TGZ="${2:+/in/$2}"
W=/work
PORT=3111
FAILS=0

say()  { printf '\n===== %s =====\n' "$*"; }
note() { printf '%s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$W/new" "$W/old" "$W/managed" "$W/log"
: > "$W/log/access.log"
: > "$W/Caddyfile"
head -c 24 /dev/urandom | base64 > "$W/pw"

say "container"
. /etc/os-release; echo "$PRETTY_NAME"; ldd --version | head -1

tar -xzf "$NEW_TGZ" -C "$W/new"
NEW="$(find "$W/new" -mindepth 1 -maxdepth 1 -type d | head -1)"
say "new release"
cat "$NEW/VERSION"; cat "$NEW/BUILDINFO"; "$NEW/bin/node" -v
if [ -n "$OLD_TGZ" ]; then
  tar -xzf "$OLD_TGZ" -C "$W/old"
  OLD="$(find "$W/old" -mindepth 1 -maxdepth 1 -type d | head -1)"
  say "old release"
  cat "$OLD/VERSION"; cat "$OLD/BUILDINFO"; "$OLD/bin/node" -v
fi

export NODE_ENV=production HOSTNAME=127.0.0.1 PORT=$PORT NEXT_TELEMETRY_DISABLED=1 TZ=UTC
export ADMIN_USERNAME=smoketest ADMIN_INITIAL_PASSWORD_FILE="$W/pw"
export ALLOW_INSECURE_LAN_HTTP=false
export CADDY_MANAGED_DIR="$W/managed" CADDY_ACCESS_LOG_FILE="$W/log/access.log" CADDY_MAIN_CADDYFILE="$W/Caddyfile"
unset CADDY_ADMIN_URL AUTH_DISABLED CERT_CHECK_PRIVATE_DOMAINS BIND_ADDRESS

PID=""
start_app() { # <release-dir> <db> <log>
  export DATABASE_PATH="$2"
  ( cd "$1/app" && exec "$1/bin/node" server.js >"$3" 2>&1 ) &
  PID=$!
}
wait_health() { # <release-dir>
  i=0
  while [ $i -lt 40 ]; do
    if "$1/bin/node" -e "fetch('http://127.0.0.1:$PORT/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" 2>/dev/null; then
      return 0
    fi
    kill -0 "$PID" 2>/dev/null || return 1
    i=$((i + 1)); sleep 1
  done
  return 1
}
stop_app() {
  kill -TERM "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null; rc=$?
  note "exit status after SIGTERM: $rc (0 or 143 is a clean stop)"
  PID=""
}
peak_rss() { grep -E 'VmHWM|VmRSS' "/proc/$PID/status" | tr -s ' \t' ' '; }

sqlite() { # <release-dir> <db> <js-expression-body>
  ( cd "$1/app" && "$1/bin/node" -e "const D=require('better-sqlite3');const db=new D('$2');$3" )
}

###########################################################################
say "A. new release, fresh database"
DB="$W/data-a.db"
mkdir -p "$W"
start_app "$NEW" "$DB" "$W/a.log"
if wait_health "$NEW"; then
  note "health: up"
  "$NEW/bin/node" /scripts/probe.mjs "http://127.0.0.1:$PORT" || bad "probe checks failed (A)"
  note "-- memory after the probe run:"; peak_rss
else
  bad "new release did not become healthy"
fi
say "A. startup log"; cat "$W/a.log"
grep -q 'database migrations applied' "$W/a.log" || bad "no 'database migrations applied' line"
grep -qE 'initial admin|admin' "$W/a.log" || note "(no admin line matched; see log)"
stop_app
sqlite "$NEW" "$DB" "console.log('migrations recorded:', db.prepare('select count(*) c from __drizzle_migrations').get().c);console.log('tables:', db.prepare(\"select name from sqlite_master where type='table' order by 1\").all().map(r=>r.name).join(', '))"

###########################################################################
if [ -n "$OLD_TGZ" ]; then
  say "B. old release creates its DB and a legacy site row"
  DB="$W/data-b.db"
  start_app "$OLD" "$DB" "$W/b-old.log"
  if wait_health "$OLD"; then
    note "old health: up"; peak_rss
  else
    bad "old release did not become healthy"
  fi
  stop_app
  sqlite "$OLD" "$DB" "
    const now=Date.now();
    db.prepare('insert into caddy_sites (id,hostname,upstream,tls,enabled,created_at,updated_at) values (?,?,?,?,?,?,?)')
      .run(require('node:crypto').randomUUID(),'legacy.example.test','http://127.0.0.1:8080','automatic',1,now,now);
    console.log('old migrations recorded:', db.prepare('select count(*) c from __drizzle_migrations').get().c);
    console.log('old caddy_sites columns:', db.prepare('pragma table_info(caddy_sites)').all().map(c=>c.name).join(', '));
    db.pragma('wal_checkpoint(TRUNCATE)');"
  cp -a "$DB" "$W/pre-upgrade.db"
  ls -l "$W"/data-b.db* 2>/dev/null

  say "C. upgrade: new release on the old database"
  start_app "$NEW" "$DB" "$W/c-new.log"
  if wait_health "$NEW"; then
    note "new health: up"
    "$NEW/bin/node" /scripts/probe.mjs "http://127.0.0.1:$PORT" || bad "probe checks failed (C)"
    peak_rss
  else
    bad "new release did not become healthy on the migrated database"
  fi
  say "C. startup log"; cat "$W/c-new.log"
  grep -q 'database migrations applied' "$W/c-new.log" || bad "no migrations line after upgrade"
  stop_app
  sqlite "$NEW" "$DB" "
    console.log('migrations recorded:', db.prepare('select count(*) c from __drizzle_migrations').get().c);
    console.log('caddy_sites columns:', db.prepare('pragma table_info(caddy_sites)').all().map(c=>c.name).join(', '));
    console.log('legacy row kept:', JSON.stringify(db.prepare(\"select hostname,kind,upstream,upstream_skip_tls_verify,upstream_headers,tls,enabled from caddy_sites\").all()));
    console.log('certificate_checks exists:', !!db.prepare(\"select 1 from sqlite_master where name='certificate_checks'\").get());
    console.log('integrity_check:', db.prepare('pragma integrity_check').get().integrity_check);
    console.log('foreign_key_check rows:', db.prepare('pragma foreign_key_check').all().length);"
  cp -a "$DB" "$W/post-upgrade.db"

  say "D. downgrade WITHOUT restoring the backup: old release on the migrated database"
  start_app "$OLD" "$DB" "$W/d-old.log"
  if wait_health "$OLD"; then
    note "RESULT D: old release starts and is healthy on the migrated database"
    peak_rss
  else
    note "RESULT D: old release does NOT come up on the migrated database"
  fi
  cat "$W/d-old.log"
  stop_app

  say "E. rollback the way install-release.sh does it: restore backup, old release, then upgrade again"
  cp -a "$W/pre-upgrade.db" "$DB"; rm -f "$DB-wal" "$DB-shm"
  start_app "$OLD" "$DB" "$W/e-old.log"
  wait_health "$OLD" && note "old release healthy on restored backup" || bad "old release unhealthy on restored backup"
  stop_app
  start_app "$NEW" "$DB" "$W/e-new.log"
  wait_health "$NEW" && note "new release healthy again after re-upgrade" || bad "re-upgrade failed"
  stop_app
fi

say "SUMMARY"
if [ "$FAILS" -eq 0 ]; then echo "SMOKE TEST: no failures"; else echo "SMOKE TEST: $FAILS failure(s)"; fi
exit "$FAILS"
