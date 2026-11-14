#!/bin/sh
# Starts the managed OpenCode service inside the container.
# The managed service (not a bare `serve`) is required: only it can mint
# pairing links for the desktop app.
set -eu

if [ -z "${OPENCODE_PASSWORD:-}" ]; then
  echo "OPENCODE_PASSWORD is required" >&2
  exit 1
fi

CONFIG_DIR="${HOME}/.config/opencode"
OVERLAY="${HOME}/.cache/opencode/container/opencode.jsonc"

# The host keeps providers in opencode.jsonc and MCP servers in opencode.json;
# merge both, in that order.
node /usr/local/lib/opencode-docker/overlay.mjs "$OVERLAY" \
  "${CONFIG_DIR}/opencode.json" "${CONFIG_DIR}/opencode.jsonc"
export OPENCODE_CONFIG="$OVERLAY"

# Idempotent; persisted in the oc-data volume so restarts keep the same values.
opencode service set hostname 0.0.0.0
opencode service set port 4097
opencode service set password "$OPENCODE_PASSWORD"
opencode service set env OPENCODE_PASSWORD "$OPENCODE_PASSWORD"
opencode service set env OPENCODE_CONFIG "$OVERLAY"

opencode service start

tail -F "${HOME}/.local/share/opencode/log/opencode.log" &
TAIL_PID=$!

shutdown() {
  kill "$TAIL_PID" 2>/dev/null || true
  opencode service stop || true
  exit 0
}
trap shutdown TERM INT

wait "$TAIL_PID"
