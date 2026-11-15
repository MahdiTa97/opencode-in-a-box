#!/bin/sh
# Show what the guardrails actually stopped. The rules are only worth having if
# you can see them working: a silent deny and a silent failure look identical
# from the outside.
#
# Usage: ./scripts/audit.sh [window]      window defaults to 24h (docker log syntax)
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env here; run ./setup.sh first" >&2; exit 1; }

window="${1:-24h}"
logs="$(sudo docker compose logs --no-color --since "$window" opencode 2>/dev/null || true)"

if [ -z "$logs" ]; then
  echo "no log output for the last $window (is the container running?)" >&2
  exit 1
fi

count() { printf '%s' "$logs" | grep -c "$1" 2>/dev/null || true; }

perm="$(count 'permission.rejected')"
policy="$(count 'Blocked by configuration policy')"
tool="$(count 'Permission denied:')"

echo "window: $window"
printf 'permission denies (agent rules) : %s\n' "$perm"
printf 'policy denies     (/etc layer)  : %s\n' "$policy"
printf 'tool-level denials (shell/read) : %s\n' "$tool"

if [ "$perm" -eq 0 ] && [ "$policy" -eq 0 ] && [ "$tool" -eq 0 ]; then
  echo
  echo "nothing was blocked — either the agent stayed in bounds, or it was idle."
  exit 0
fi

echo
echo "most recent denials:"
printf '%s\n' "$logs" \
  | grep -E 'permission\.rejected|Blocked by configuration policy|Permission denied:' \
  | sed 's/^[[:space:]]*//' \
  | tail -n 8 \
  | cut -c1-160 \
  | sed 's/^/  /'
