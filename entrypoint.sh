#!/bin/sh
# Starts the managed OpenCode service inside the container.
# The managed service (not a bare `serve`) is required: only it can mint
# pairing links for the desktop app.
set -eu

if [ -z "${OPENCODE_PASSWORD:-}" ]; then
  echo "OPENCODE_PASSWORD is required" >&2
  exit 1
fi

OVERLAY="${HOME}/.cache/opencode/container/opencode.jsonc"
node /usr/local/lib/opencode-docker/overlay.mjs \
  "${HOME}/.config/opencode/opencode.jsonc" "$OVERLAY"
export OPENCODE_CONFIG="$OVERLAY"

# Idempotent; persisted in the oc-data volume so restarts keep the same values.
opencode service set hostname 0.0.0.0
opencode service set port 4097
opencode service set password "$OPENCODE_PASSWORD"
opencode service set env OPENCODE_PASSWORD "$OPENCODE_PASSWORD"

opencode service start

exec tail -F "${HOME}/.local/share/opencode/log/opencode.log"
