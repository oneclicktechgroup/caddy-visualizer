#!/bin/sh
# Runs INSIDE a Debian 13 container as root (same glibc as CT109). Never touches CT109.
#   smoke4.sh <new-release.tar.gz> <old-release.tar.gz>
# Tarballs are read from /in, the installer from /install/install-release.sh (both mounted read-only).
#
# Runs the REAL install-release.sh against a running "old" release, with a small stand-in for
# systemctl (there is no systemd in the container: `stop` sends SIGTERM and waits, `start` launches the
# app from the `current` link). It checks what systemd, the unit and the real paths would not change:
# that the database backup the installer makes is complete, and that a failed backup leaves the old
# release running.
set -u

NEW_TGZ="/in/$1"
OLD_TGZ="/in/$2"
INSTALLER=/install/install-release.sh
APP=/opt/caddy-visualizer
DATA=/var/lib/caddy-visualizer/data
DB="$DATA/caddy-visualizer.db"
BACKUPS="$DATA/backups"
PORT=3111
FAILS=0

say()  { printf '\n===== %s =====\n' "$*"; }
note() { printf '%s\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
bad()  { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*"; }

mkdir -p "$APP/releases" "$DATA" /etc/caddy-visualizer /work/managed /work/log /work/chk
: > /work/log/access.log
: > /work/Caddyfile
head -c 24 /dev/urandom | base64 > /work/pw

cat > /etc/caddy-visualizer/env <<EOF
NODE_ENV=production
HOSTNAME=127.0.0.1
PORT=$PORT
NEXT_TELEMETRY_DISABLED=1
DATABASE_PATH=$DB
ADMIN_USERNAME=smoketest
ADMIN_INITIAL_PASSWORD_FILE=/work/pw
ALLOW_INSECURE_LAN_HTTP=false
CADDY_MANAGED_DIR=/work/managed
CADDY_ACCESS_LOG_FILE=/work/log/access.log
CADDY_MAIN_CADDYFILE=/work/Caddyfile
EOF

# Stand-in for systemctl. A killed child that nobody reaps stays a zombie, so "alive" ignores state Z.
cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
PIDFILE=/work/app.pid
alive() { [ -d "/proc/$1" ] && ! grep -q '^State:[[:space:]]*Z' "/proc/$1/status"; }
case "$1" in
  stop)
    if [ -f "$PIDFILE" ]; then
      pid="$(cat "$PIDFILE")"
      kill -TERM "$pid" 2>/dev/null
      i=0
      while alive "$pid" && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
      rm -f "$PIDFILE"
    fi
    ;;
  start)
    set -a; . /etc/caddy-visualizer/env; set +a
    cd /opt/caddy-visualizer/current/app || exit 1
    /opt/caddy-visualizer/current/bin/node server.js >> /work/service.log 2>&1 &
    echo $! > "$PIDFILE"
    ;;
esac
exit 0
EOF
chmod 755 /usr/local/bin/systemctl

up() { "$APP/current/bin/node" -e "fetch('http://127.0.0.1:$PORT/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" 2>/dev/null; }
wait_up() { i=0; while [ "$i" -lt 40 ]; do up && return 0; i=$((i + 1)); sleep 1; done; return 1; }

# Prints "tables=N migrations=N users=N integrity=ok" for a database file. Run on a copy, never on a
# file that matters: opening a WAL database can create -wal/-shm files next to it.
dbcount() { # <release-dir> <db-file>
  ( cd "$1/app" && "$1/bin/node" -e "
    const D = require('better-sqlite3');
    const db = new D(process.argv[1], { readonly: true, fileMustExist: true });
    const n = (q) => { try { return db.prepare(q).get().c; } catch (e) { return -1; } };
    console.log('tables=' + n(\"select count(*) c from sqlite_master where type='table'\")
      + ' migrations=' + n('select count(*) c from __drizzle_migrations')
      + ' users=' + n('select count(*) c from users')
      + ' integrity=' + db.pragma('integrity_check', { simple: true }));
    db.close();" "$2" )
}

###########################################################################
say "setup: the old release is the running one"
tar -xzf "$OLD_TGZ" -C "$APP/releases"
d="$(find "$APP/releases" -mindepth 1 -maxdepth 1 -type d | head -1)"
OLDVER="$(head -n1 "$d/VERSION")"
mv "$d" "$APP/releases/$OLDVER"
chown -R root:root "$APP/releases"
ln -sfn "$APP/releases/$OLDVER" "$APP/current"
NEWVER="$(tar -xzOf "$NEW_TGZ" --wildcards '*/VERSION' | head -n1)"
note "old release: $OLDVER, new release: $NEWVER"

systemctl start caddy-visualizer
if wait_up; then pass "old release is up"; else bad "old release did not start"; cat /work/service.log; fi
sleep 12   # let it write for a while; its writes sit in the -wal file until a checkpoint

cp -a "$DB" /work/chk/live.db
cp -a "${DB}-wal" /work/chk/live.db-wal 2>/dev/null || note "(no -wal file next to the live database)"
EXPECT="$(dbcount "$APP/current" /work/chk/live.db)"
rm -f /work/chk/live.db /work/chk/live.db-wal /work/chk/live.db-shm
note "live database before the update (main file + -wal): $EXPECT"
case "$EXPECT" in *migrations=0*|*migrations=-1*) bad "no migrations in the live database; the test setup is wrong";; esac

###########################################################################
say "B. the backup fold fails: the old release must keep running and nothing may be left behind"
# Makes node throw only when it is asked to open something under /backups/ (the fold step).
cat > /work/boom.js <<'EOF'
if ((process.argv[1] || '').includes('/backups/')) throw new Error('simulated failure in the backup fold');
EOF
NODE_OPTIONS="--require=/work/boom.js" bash "$INSTALLER" "$NEW_TGZ" > /work/inst-b.out 2>&1
rc=$?
grep -E '^(==>|ERROR:|Installed)' /work/inst-b.out
[ "$rc" -ne 0 ] && pass "installer exits non-zero [$rc]" || bad "installer succeeded although the fold failed"
grep -q 'could not fold' /work/inst-b.out && pass "installer says why" || bad "no 'could not fold' message"
[ ! -e "$APP/releases/$NEWVER" ] && pass "the new release directory was removed" || bad "new release directory left behind"
[ "$(basename "$(readlink -f "$APP/current")")" = "$OLDVER" ] && pass "current still points at the old release" || bad "current moved"
if wait_up; then pass "old release is running again"; else bad "old release is not running after the failed fold"; fi
left="$(ls -A "$BACKUPS" 2>/dev/null | wc -l)"
[ "$left" -eq 0 ] && pass "no backup files left behind" || { bad "backups directory is not empty ($left)"; ls -l "$BACKUPS"; }

###########################################################################
say "C. normal update: the backup must hold everything the live database held"
sleep 5
cp -a "$DB" /work/chk/live.db
cp -a "${DB}-wal" /work/chk/live.db-wal 2>/dev/null || true
EXPECT="$(dbcount "$APP/current" /work/chk/live.db)"
rm -f /work/chk/live.db /work/chk/live.db-wal /work/chk/live.db-shm
note "live database before the update (main file + -wal): $EXPECT"

bash "$INSTALLER" "$NEW_TGZ" > /work/inst-c.out 2>&1
rc=$?
grep -E '^(==>|ERROR:|Installed)' /work/inst-c.out
[ "$rc" -eq 0 ] && pass "installer exits 0" || bad "installer failed [$rc]"
grep -q "==> $NEWVER is healthy" /work/inst-c.out && pass "installer reports the new release healthy" || bad "no 'is healthy' line"
[ "$(basename "$(readlink -f "$APP/current")")" = "$NEWVER" ] && pass "current points at the new release" || bad "current does not point at the new release"

nfiles="$(ls -A "$BACKUPS" | wc -l)"
[ "$nfiles" -eq 1 ] && pass "exactly one file in the backups directory" || { bad "backups directory holds $nfiles files"; ls -l "$BACKUPS"; }
if ls "$BACKUPS" | grep -qE -- '-(wal|shm)$'; then bad "backups directory holds -wal/-shm files"; else pass "no -wal/-shm files in the backups directory"; fi
BK="$(ls "$BACKUPS" | head -1)"
case "$BK" in caddy-visualizer.db.pre-"$NEWVER"-*) pass "backup is named for the new release [$BK]";; *) bad "unexpected backup name: $BK";; esac

cp -a "$BACKUPS/$BK" /work/chk/backup.db
GOT="$(dbcount "$APP/current" /work/chk/backup.db)"
note "backup (the file alone, no -wal):                      $GOT"
[ "$GOT" = "$EXPECT" ] && pass "the backup alone holds what the live database held" || bad "backup differs from the live database: expected [$EXPECT], got [$GOT]"
case "$GOT" in *integrity=ok*) pass "backup integrity check ok";; *) bad "backup integrity check not ok";; esac

cp -a "$DB" /work/chk/after.db
cp -a "${DB}-wal" /work/chk/after.db-wal 2>/dev/null || true
note "live database after the update:                       $(dbcount "$APP/current" /work/chk/after.db)"

systemctl stop caddy-visualizer

say "SUMMARY"
if [ "$FAILS" -eq 0 ]; then echo "SMOKE4: no failures"; else echo "SMOKE4: $FAILS failure(s)"; fi
