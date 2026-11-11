#!/usr/bin/env bash
# Validates a built release tarball in Linux containers on this machine. It never touches CT109.
#
#   ./deploy/ct109/smoke/run.sh dist/caddy-visualizer-<new>-linux-x64.tar.gz [dist/caddy-visualizer-<old>-linux-x64.tar.gz]
#
# <new> is the build you intend to install. <old> is the release CT109 runs today (or any older
# build of the same app); with it the upgrade, downgrade, restore and memory-comparison tests run too.
#
# Runs in Debian 13 (same glibc as CT109) with a real Caddy binary, so the admin socket, login,
# every page, access-log ingestion and the certificate checks are exercised. Takes about 5 minutes
# (two scripts wait 75 s for the first scheduled certificate check). Needs Docker and internet
# (pulls debian:trixie-slim and caddy:<version> once). The log is written to dist/smoke-<new>.log.
#
# Not covered: systemd, install-release.sh, and anything that needs root on CT109.
set -euo pipefail

# Git Bash on Windows would otherwise rewrite container paths such as /in/... .
export MSYS_NO_PATHCONV=1

fail() { echo "ERROR: $*" >&2; exit 1; }

NEW="${1:-}"
OLD="${2:-}"
[ -n "$NEW" ] || fail "usage: $0 <new-release.tar.gz> [<old-release.tar.gz>]"

cd "$(git rev-parse --show-toplevel)"
CADDY_VERSION="${CADDY_VERSION:-2.11.4}"   # keep equal to the Caddy on CT109
IMAGE="cv-smoke-caddy:${CADDY_VERSION}"

command -v docker >/dev/null || fail "docker not found"
docker info >/dev/null 2>&1 || fail "the Docker engine is not running (start Docker Desktop and wait until it is ready)"
[ -f "$NEW" ] || fail "not found: $NEW"
[ -z "$OLD" ] || [ -f "$OLD" ] || fail "not found: $OLD"
for f in "$NEW" "$OLD"; do
  [ -n "$f" ] && [ -f "${f}.sha256" ] && ( cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" )
done

# Windows-style absolute paths for Docker Desktop under Git Bash, plain paths elsewhere.
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$(readlink -f "$1")"; else readlink -f "$1"; fi
}
NEW_NAME="$(basename "$NEW")"
OLD_NAME="$([ -n "$OLD" ] && basename "$OLD" || true)"
SCRIPTS="$(native deploy/ct109/smoke)"
VERSION_TAG="${NEW_NAME#caddy-visualizer-}"; VERSION_TAG="${VERSION_TAG%-linux-x64.tar.gz}"
mkdir -p dist
LOG="dist/smoke-${VERSION_TAG}.log"
: > "$LOG"

echo "==> building the test image ($IMAGE: Debian 13 + Caddy ${CADDY_VERSION})"
printf 'FROM caddy:%s AS c\nFROM debian:trixie-slim\nCOPY --from=c /usr/bin/caddy /usr/local/bin/caddy\n' "$CADDY_VERSION" \
  | docker build -q -t "$IMAGE" - >/dev/null

mounts=( -v "$(native "$NEW"):/in/${NEW_NAME}:ro" -v "${SCRIPTS}:/scripts:ro" )
[ -z "$OLD" ] || mounts+=( -v "$(native "$OLD"):/in/${OLD_NAME}:ro" )

rc=0
run() { # <title> <script> <args...>
  local title="$1"; shift
  echo; echo "################ ${title} ################" | tee -a "$LOG"
  # Not `set -e` here: a failing test must not stop the next one from running.
  docker run --rm "${mounts[@]}" "$IMAGE" sh "/scripts/$@" 2>&1 | tee -a "$LOG" || true
  # tee hides the container's exit status; the scripts print a summary line instead.
}

run "1/3 fresh start${OLD:+, upgrade, downgrade, restore}" smoke.sh "$NEW_NAME" ${OLD:+"$OLD_NAME"}
run "2/3 real Caddy: login, pages, access log, certificate checks" smoke2.sh "$NEW_NAME"
[ -z "$OLD" ] || run "3/3 memory, old vs new" smoke3.sh "$NEW_NAME" "$OLD_NAME"

echo
if grep -qE 'FAIL|SMOKE TEST: [1-9]|SMOKE2: [1-9]|CHECK\(S\) FAILED|Traceback|Error: ' "$LOG"; then
  echo "SMOKE TESTS: FAILURES FOUND, read $LOG"; rc=1
else
  echo "SMOKE TESTS: no failures (log: $LOG)"
fi
exit "$rc"
