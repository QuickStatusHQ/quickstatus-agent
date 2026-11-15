#!/usr/bin/env bash
# Install tests across distros against the stub API. Needs Docker and python3 with jsonschema.
#   tests/run.sh [image ...]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGES=("$@")
[ ${#IMAGES[@]} -gt 0 ] || IMAGES=(ubuntu:24.04 debian:12 alpine:3.20 rockylinux:9-minimal)
PY="${PYTHON:-python3}"
PORT="${STUB_PORT:-18080}"
WORK="$(mktemp -d)"
LOG="$WORK/requests.jsonl"
"$PY" tests/stub_server.py --port "$PORT" --log "$LOG" &
STUB_PID=$!
FILES_PID=""
trap 'kill $STUB_PID $FILES_PID 2>/dev/null; rm -rf "$WORK"' EXIT
# A release as GitHub would serve it, plus a copy with one file changed after signing.
mkdir -p "$WORK/release/tampered"
cp quickstatus-agent.sh install.sh uninstall.sh systemd/* "$WORK/release/"
if command -v sha256sum >/dev/null; then SUM=(sha256sum); else SUM=(shasum -a 256); fi
(cd "$WORK/release" && "${SUM[@]}" -- *.sh *.service *.timer > SHA256SUMS)
cp "$WORK"/release/*.* "$WORK"/release/SHA256SUMS "$WORK/release/tampered/"
echo "# changed" >> "$WORK/release/tampered/quickstatus-agent.sh"
"$PY" -m http.server "$((PORT + 1))" --directory "$WORK/release" >/dev/null 2>&1 &
FILES_PID=$!
sleep 1

failed=0
for image in "${IMAGES[@]}"; do
  echo "=== $image"
  : > "$LOG"
  if docker run --rm --add-host=host.docker.internal:host-gateway -v "$PWD:/src:ro" \
      -e STUB="http://host.docker.internal:$PORT" -e QUICKSTATUS_ALLOW_HTTP=1 \
      -e RELEASE="http://host.docker.internal:$((PORT + 1))" "$image" sh /src/tests/in_container.sh; then
    "$PY" tests/check_log.py "$LOG" || failed=1
  else
    failed=1
  fi
done
exit $failed
