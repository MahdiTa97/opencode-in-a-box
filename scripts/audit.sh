#!/bin/sh
# Show what the guardrails actually stopped. The rules are only worth having if
# you can see them working: a silent deny and a silent failure look identical
# from the outside.
#
# Usage: ./scripts/audit.sh [window]      window defaults to 24h
#   Accepts docker durations (30m, 24h) plus days and weeks (7d, 2w), which
#   docker itself does not: those are converted to hours before the call.
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env here; run ./setup.sh first" >&2; exit 1; }

window="${1:-24h}"

# docker --since understands ns/us/ms/s/m/h, not days or weeks. Convert, and
# refuse anything that is not a number followed by a supported unit.
amount=${window%?}
unit=${window#"$amount"}
case "$unit" in
  d|w)
    case "$amount" in
      ''|*[!0-9]*) echo "not a window: $window (try 24h, 7d, 2w)" >&2; exit 2 ;;
    esac
    [ "$unit" = d ] && since=$((amount * 24))h || since=$((amount * 168))h
    ;;
  s|m|h|ns|us|ms)
    since="$window"
    ;;
  *)
    echo "not a window: $window (try 30m, 24h, 7d, 2w)" >&2
    exit 2
    ;;
esac

tmp=$(mktemp) || { echo "cannot create a temp file" >&2; exit 1; }
trap 'rm -f "$tmp"' EXIT INT TERM

if ! sudo docker compose logs --no-color --since "$since" opencode >"$tmp" 2>&1; then
  echo "docker compose logs failed:" >&2
  sed 's/^/  /' "$tmp" >&2
  exit 1
fi

if [ ! -s "$tmp" ]; then
  echo "no log output for the last $window (is the container running?)" >&2
  exit 1
fi

logs=$(cat "$tmp")
trap - EXIT INT TERM
rm -f "$tmp"

count() { printf '%s\n' "$logs" | grep -c "$1" 2>/dev/null || true; }

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
