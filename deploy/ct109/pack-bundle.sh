#!/bin/sh
# Runs INSIDE the build container (started by build-bundle.sh, script piped in on stdin).
# Packs the release tarball there, so symlinks and file modes never touch the host's
# file system. (Next.js' standalone output contains a symlink; copying that tree onto
# Windows with `docker cp` fails without the symlink privilege.)
#
# Inputs (environment): VERSION, COMMIT. Optional overrides, used for testing outside
# the image: APP_SRC (default /app), NODE_BIN (default /usr/local/bin/node), OUT (default /out).
set -eu

: "${VERSION:?VERSION is required}"
: "${COMMIT:?COMMIT is required}"
APP_SRC="${APP_SRC:-/app}"
NODE_BIN="${NODE_BIN:-/usr/local/bin/node}"
OUT="${OUT:-/out}"
NAME="caddy-visualizer-${VERSION}"

fail() { echo "ERROR: $*" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="${STAGE}/${NAME}"
mkdir -p "${ROOT}/bin" "${ROOT}/app" "$OUT"

echo "==> collecting files"
cp -a "${APP_SRC}/.next/standalone/." "${ROOT}/app/"
mkdir -p "${ROOT}/app/.next"
cp -a "${APP_SRC}/.next/static" "${ROOT}/app/.next/"
cp -a "${APP_SRC}/public" "${ROOT}/app/"
cp -a "${APP_SRC}/drizzle" "${ROOT}/app/"
cp -L "$NODE_BIN" "${ROOT}/bin/node"

echo "==> checking the result"
[ -f "${ROOT}/app/server.js" ] || fail "server.js missing"
[ -d "${ROOT}/app/.next/static" ] || fail ".next/static missing"
[ -d "${ROOT}/app/public" ] || fail "public missing"
[ -f "${ROOT}/app/drizzle/meta/_journal.json" ] || fail "drizzle migrations missing"
[ -f "${ROOT}/app/node_modules/better-sqlite3/prebuilds/linux-x64.node" ] \
  || fail "better-sqlite3 linux-x64 prebuild missing"

# Every symlink must resolve inside the bundle (the server loads better-sqlite3 through one).
broken="$(find "${ROOT}/app" -type l ! -exec test -e {} \; -print)"
[ -z "$broken" ] || fail "broken symlinks in the bundle: $broken"
links="$(find "${ROOT}/app" -type l | wc -l)"

# The bundled Node must be able to load the native SQLite module.
( cd "${ROOT}/app" && "${ROOT}/bin/node" -e "new (require('better-sqlite3'))(':memory:').close()" </dev/null ) \
  || fail "bundled node cannot load better-sqlite3"

NODE_VERSION="$("${ROOT}/bin/node" -v)"
echo "$VERSION" > "${ROOT}/VERSION"
{
  echo "version=${VERSION}"
  echo "node=${NODE_VERSION}"
  echo "commit=${COMMIT}"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${ROOT}/BUILDINFO"

TARBALL="${NAME}-linux-x64.tar.gz"
tar -czf "${OUT}/${TARBALL}" --owner=0 --group=0 --numeric-owner -C "$STAGE" "$NAME"
( cd "$OUT" && sha256sum "$TARBALL" > "${TARBALL}.sha256" )

echo "==> packed ${TARBALL} ($(du -h "${OUT}/${TARBALL}" | cut -f1), node ${NODE_VERSION}, ${links} symlink(s))"
