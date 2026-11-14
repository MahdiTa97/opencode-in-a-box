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
HOST_CONFIG_DIR="${HOST_CONFIG_DIR:-/home/dev/host-config}"
OVERLAY="${HOME}/.cache/opencode/container/opencode.jsonc"

# The container's global config directory holds only the things OpenCode reads
# from it (skills, agents, commands, AGENTS.md). The config files themselves are
# never placed here: OPENCODE_CONFIG only overrides the keys it defines, so a
# host global config would leak `browse` and credential-less providers into the
# running server.
mkdir -p "$CONFIG_DIR"
for entry in skills agents commands AGENTS.md; do
  if [ -e "${HOST_CONFIG_DIR}/${entry}" ]; then
    rm -rf "${CONFIG_DIR:?}/${entry}"
    cp -R "${HOST_CONFIG_DIR}/${entry}" "${CONFIG_DIR}/${entry}"
  fi
done

# The host keeps providers in opencode.jsonc and MCP servers in opencode.json;
# merge both, in that order.
node /usr/local/lib/opencode-docker/overlay.mjs "$OVERLAY" \
  "${HOST_CONFIG_DIR}/opencode.json" "${HOST_CONFIG_DIR}/opencode.jsonc"
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

# Watchdog: the managed service is a child of this process, so if it dies the
# container would otherwise stay "up" while serving nothing. Exit non-zero and
# let Compose restart us.
server_alive() {
  for proc in /proc/[0-9]*; do
    [ -r "${proc}/cmdline" ] || continue
    if tr '\0' ' ' < "${proc}/cmdline" 2>/dev/null | grep -q 'serve --service'; then
      return 0
    fi
  done
  return 1
}

while kill -0 "$TAIL_PID" 2>/dev/null; do
  sleep 15
  if ! server_alive; then
    echo "opencode server process is gone; exiting so Compose can restart" >&2
    exit 1
  fi
done

