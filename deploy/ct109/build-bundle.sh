#!/usr/bin/env bash
# Builds a release tarball for a native (non-Docker) install on Debian 12+ amd64.
#
# Run from anywhere inside the repository (Docker Desktop must be running):
#   ./deploy/ct109/build-bundle.sh [version]
#
# Output: dist/caddy-visualizer-<version>-linux-x64.tar.gz  (+ .sha256)
#
# The build runs in the repo's own Dockerfile "build" stage (node:24-bookworm-slim).
# The tarball is packed INSIDE the container (pack-bundle.sh) and only that one file is
# copied out, so nothing with symlinks or Unix modes is written to the host's file system
# (no Windows symlink privilege or Developer Mode needed). The Dockerfile's distroless
# runtime stage is not used and not pulled.
set -euo pipefail

# Git Bash on Windows would otherwise rewrite container paths such as /out/... .
export MSYS_NO_PATHCONV=1

cd "$(git rev-parse --show-toplevel)"

VERSION="${1:-$(git describe --always --dirty --abbrev=8)}"
VERSION="${VERSION//[^A-Za-z0-9._-]/_}"
IMAGE="caddy-visualizer-build:${VERSION}"
CONTAINER="caddy-visualizer-pack-${VERSION}-$$"
OUT="dist"
PACK_SCRIPT="deploy/ct109/pack-bundle.sh"

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }

command -v docker >/dev/null || fail "docker not found"
docker info >/dev/null 2>&1 || fail "the Docker engine is not running (start Docker Desktop and wait until it is ready)"
[ -f "$PACK_SCRIPT" ] || fail "$PACK_SCRIPT not found"
if grep -q $'\r' "$PACK_SCRIPT"; then
  fail "$PACK_SCRIPT has Windows line endings; run: git add --renormalize deploy && git checkout -- deploy"
fi

echo "==> docker build (target: build, needs internet for npm and Google Fonts)"
docker build --target build -t "$IMAGE" .

echo "==> packing inside the container"
# The script is fed on stdin; the container is kept (no --rm) so the result can be copied out.
docker run -i --name "$CONTAINER" \
  -e "VERSION=${VERSION}" -e "COMMIT=$(git rev-parse HEAD)" \
  --entrypoint sh "$IMAGE" -s < "$PACK_SCRIPT"

mkdir -p "$OUT"
docker cp "${CONTAINER}:/out/." "${OUT}/"

TARBALL="${OUT}/caddy-visualizer-${VERSION}-linux-x64.tar.gz"
[ -f "$TARBALL" ] || fail "tarball not found after copy: $TARBALL"

echo "==> verifying the copy on this machine"
( cd "$OUT" && sha256sum -c "$(basename "$TARBALL").sha256" )
tar -tzf "$TARBALL" | grep -q "/app/server.js$" || fail "server.js not in the tarball"
tar -tzf "$TARBALL" | grep -q "/bin/node$" || fail "bin/node not in the tarball"

echo
echo "Built ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
echo "Copy it and its .sha256 file to the container, then run install-release.sh there."
