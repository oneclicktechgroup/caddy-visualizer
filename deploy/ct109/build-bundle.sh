#!/usr/bin/env bash
# Builds a release tarball for a native (non-Docker) install on Debian 12+ amd64.
#
# Run from anywhere inside the repository (Docker Desktop or Docker Engine required):
#   ./deploy/ct109/build-bundle.sh [version]
#
# Output: dist/caddy-visualizer-<version>-linux-x64.tar.gz  (+ .sha256)
#
# The build runs in the repo's own Dockerfile "build" stage (node:24-bookworm-slim),
# so the bundle holds Linux files plus the exact Node binary it was built with.
# The runtime stage of the Dockerfile (distroless) is not used and not pulled.
set -euo pipefail

# Git Bash on Windows would otherwise rewrite container paths such as /app/... .
export MSYS_NO_PATHCONV=1

cd "$(git rev-parse --show-toplevel)"

VERSION="${1:-$(git describe --always --dirty --abbrev=8)}"
VERSION="${VERSION//[^A-Za-z0-9._-]/_}"
NAME="caddy-visualizer-${VERSION}"
IMAGE="caddy-visualizer-build:${VERSION}"
OUT="dist"
# Relative on purpose: docker.exe on Windows does not understand Git Bash's /tmp paths.
STAGE="${OUT}/.stage-${VERSION}"
APP="${STAGE}/${NAME}/app"
CID=""

cleanup() {
  if [ -n "$CID" ]; then docker rm -f "$CID" >/dev/null 2>&1 || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found"

rm -rf "$STAGE"
mkdir -p "${STAGE}/${NAME}/bin" "$APP"

echo "==> docker build (target: build, needs internet for npm and Google Fonts)"
docker build --target build -t "$IMAGE" .

CID="$(docker create "$IMAGE")"

echo "==> collecting files"
docker cp "${CID}:/app/.next/standalone/." "${APP}/"
docker cp "${CID}:/app/.next/static" "${APP}/.next/"
docker cp "${CID}:/app/public" "${APP}/"
docker cp "${CID}:/app/drizzle" "${APP}/"
docker cp -L "${CID}:/usr/local/bin/node" "${STAGE}/${NAME}/bin/node"

echo "==> checking the result"
[ -f "${APP}/server.js" ] || fail "server.js missing"
[ -d "${APP}/.next/static" ] || fail ".next/static missing"
[ -d "${APP}/public" ] || fail "public missing"
[ -f "${APP}/drizzle/meta/_journal.json" ] || fail "drizzle migrations missing"
[ -f "${APP}/node_modules/better-sqlite3/prebuilds/linux-x64.node" ] \
  || fail "better-sqlite3 linux-x64 prebuild missing"
[ "$(head -c 4 "${STAGE}/${NAME}/bin/node" | tail -c 3)" = "ELF" ] \
  || fail "bin/node is not a Linux binary"

NODE_VERSION="$(docker run --rm --entrypoint node "$IMAGE" -v | tr -d '\r')"
echo "$VERSION" > "${STAGE}/${NAME}/VERSION"
{
  echo "version=${VERSION}"
  echo "node=${NODE_VERSION}"
  echo "commit=$(git rev-parse HEAD)"
  echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${STAGE}/${NAME}/BUILDINFO"

mkdir -p "$OUT"
TARBALL="${OUT}/${NAME}-linux-x64.tar.gz"
# NTFS has no Unix modes or owners; install-release.sh normalises both on the server.
tar -czf "$TARBALL" --owner=0 --group=0 -C "$STAGE" "$NAME"
( cd "$OUT" && sha256sum "${NAME}-linux-x64.tar.gz" > "${NAME}-linux-x64.tar.gz.sha256" )

echo
echo "Built ${TARBALL} ($(du -h "$TARBALL" | cut -f1), node ${NODE_VERSION})"
echo "Copy it to the container together with the .sha256 file, then run install-release.sh there."
