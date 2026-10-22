#!/usr/bin/env bash
# Installs a release built by build-bundle.sh and restarts the service.
# Run as root on the container:
#   /opt/caddy-visualizer/install-release.sh /tmp/caddy-visualizer-<ver>-linux-x64.tar.gz
#
# Before switching it backs up the SQLite database; if /api/health does not answer
# after the restart it switches back to the previous release and restores that backup
# (a newer release may have migrated the database, which the old code can't read).
set -euo pipefail

APP_DIR=/opt/caddy-visualizer
SERVICE=caddy-visualizer
ENV_FILE=/etc/caddy-visualizer/env
KEEP_RELEASES=3
KEEP_DB_BACKUP_FILES=6

fail() { echo "ERROR: $*" >&2; exit 1; }

tarball="${1:-}"
[ -n "$tarball" ] || fail "usage: $0 <release.tar.gz>"
[ "$(id -u)" -eq 0 ] || fail "run as root"
[ -f "$tarball" ] || fail "not found: $tarball"
[ -f "$ENV_FILE" ] || fail "missing $ENV_FILE (see README, one-time setup)"

if [ -f "${tarball}.sha256" ]; then
  ( cd "$(dirname "$tarball")" && sha256sum -c "$(basename "$tarball").sha256" )
else
  echo "warning: no .sha256 next to the tarball; skipping verification" >&2
fi

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1; }
PORT="$(env_value PORT)"; PORT="${PORT:-3000}"
DB_PATH="$(env_value DATABASE_PATH)"

install -d -m 755 "${APP_DIR}/releases"
incoming="$(mktemp -d "${APP_DIR}/releases/.incoming.XXXXXX")"
trap 'rm -rf "$incoming"' EXIT
tar -xzf "$tarball" -C "$incoming"

src="$(find "$incoming" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$src" ] && [ -f "$src/VERSION" ] && [ -f "$src/app/server.js" ] \
  || fail "not a valid release tarball"
version="$(head -n 1 "$src/VERSION")"
dest="${APP_DIR}/releases/${version}"
[ ! -e "$dest" ] || fail "release ${version} is already installed"

# Code is root-owned and not writable by the service user.
chown -R root:root "$src"
chmod -R go-w,a+rX "$src"
chmod 0755 "$src/bin/node"
mv "$src" "$dest"

echo "==> checking the bundle runs on this system"
if ! ( cd "$dest/app" && "$dest/bin/node" -e "new (require('better-sqlite3'))(':memory:').close()" ); then
  rm -rf "$dest"
  fail "node or the SQLite module cannot run here (glibc older than 2.34?). Nothing was changed."
fi

previous="$(readlink -f "${APP_DIR}/current" 2>/dev/null || true)"

systemctl stop "$SERVICE" 2>/dev/null || true

backup=""
if [ -n "$DB_PATH" ] && [ -f "$DB_PATH" ]; then
  backup_dir="$(dirname "$DB_PATH")/backups"
  install -d -m 700 -o root -g root "$backup_dir"
  backup="${backup_dir}/$(basename "$DB_PATH").pre-${version}-$(date +%Y%m%d-%H%M%S)"
  cp -a "$DB_PATH" "$backup"
  # Files beyond the newest KEEP_DB_BACKUP_FILES are removed.
  # shellcheck disable=SC2012
  ls -1t "$backup_dir" | tail -n +"$((KEEP_DB_BACKUP_FILES + 1))" | while read -r old; do
    rm -f -- "${backup_dir}/${old}"
  done
fi

switch_to() {
  ln -sfn "$1" "${APP_DIR}/current.new"
  mv -T "${APP_DIR}/current.new" "${APP_DIR}/current"
}

wait_healthy() {
  for _ in $(seq 1 30); do
    if "${APP_DIR}/current/bin/node" -e \
      "fetch('http://127.0.0.1:${PORT}/api/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "==> switching to ${version}"
switch_to "$dest"
systemctl start "$SERVICE"

if wait_healthy; then
  echo "==> ${version} is healthy"
else
  echo "ERROR: ${version} did not become healthy; last log lines:" >&2
  journalctl -u "$SERVICE" -n 30 --no-pager >&2 || true
  systemctl stop "$SERVICE" 2>/dev/null || true
  rm -rf "$dest"
  if [ -n "$previous" ] && [ -d "$previous" ]; then
    echo "==> rolling back to $(basename "$previous")" >&2
    switch_to "$previous"
    if [ -n "$backup" ] && [ -f "$backup" ]; then
      cp -a "$backup" "$DB_PATH"
      rm -f "${DB_PATH}-wal" "${DB_PATH}-shm"
    fi
    systemctl start "$SERVICE"
    wait_healthy && echo "==> previous release is running again" >&2 \
      || echo "ERROR: the previous release did not come back either; check journalctl -u ${SERVICE}" >&2
  else
    echo "No previous release to roll back to." >&2
  fi
  exit 1
fi

# Keep the newest releases; never remove the active one.
current="$(readlink -f "${APP_DIR}/current")"
# shellcheck disable=SC2012
ls -1dt "${APP_DIR}"/releases/*/ | tail -n +"$((KEEP_RELEASES + 1))" | while read -r old; do
  [ "$(readlink -f "$old")" = "$current" ] || rm -rf -- "$old"
done

echo "Installed ${version}. Previous: ${previous:-none}."
