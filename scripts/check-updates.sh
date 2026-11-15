#!/bin/sh
# Report how far the versions pinned in the Dockerfile are from the latest
# releases on npm. Informational only: it changes nothing and always exits 0
# unless the Dockerfile cannot be read.
#
# Usage: ./scripts/check-updates.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
dockerfile="$repo/Dockerfile"

[ -r "$dockerfile" ] || { echo "cannot read $dockerfile" >&2; exit 1; }

# Ask the registry directly instead of shelling out to `npm view`: the timer runs
# this as root, where a user-local node toolchain is not on PATH.
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

latest_version() {
  # Scoped names must be encoded: @scope/name -> @scope%2fname
  encoded=$(printf '%s' "$1" | sed 's|/|%2f|')
  curl -fsS --max-time 10 "https://registry.npmjs.org/$encoded/latest" 2>/dev/null |
    jq -r '.version // empty' 2>/dev/null
}

# Pull the spec for a package out of the Dockerfile: the first `name@version`
# token that survives splitting on quotes, spaces and backslashes.
current_spec() {
  tr '\\" ' '\n\n\n' <"$dockerfile" |
    sed 's/^ *//' |
    grep -o "^$1@[A-Za-z0-9.^~-]*" |
    head -1
}

printf '%-26s %-12s %-12s %s\n' 'package' 'pinned' 'latest' 'status'
printf '%-26s %-12s %-12s %s\n' '--------------------------' '------------' '------------' '------'

status_all=0
for pkg in @opencode/cli @upstash/context7-mcp pnpm yarn playwright; do
  spec=$(current_spec "$pkg")
  if [ -z "$spec" ]; then
    printf '%-26s %-12s %-12s %s\n' "$pkg" '-' '-' 'not pinned'
    continue
  fi
  pinned=${spec#"$pkg@"}
  plain=$(printf '%s' "$pinned" | sed 's/^[\^~]//')

  latest=$(latest_version "$pkg") || latest=''
  [ -n "$latest" ] || { printf '%-26s %-12s %-12s %s\n' "$pkg" "$pinned" '?' 'lookup failed (offline?)'; continue; }

  if [ "$plain" = "$latest" ]; then
    state='up to date'
  else
    major_pinned=${plain%%.*}
    major_latest=${latest%%.*}
    if [ "$major_pinned" = "$major_latest" ]; then
      state='newer minor/patch available'
    else
      state='MAJOR version available - read its changelog first'
      status_all=1
    fi
  fi
  printf '%-26s %-12s %-12s %s\n' "$pkg" "$pinned" "$latest" "$state"
done

echo
node_pin=$(sed -n 's/^ARG NODE_IMAGE=//p' "$dockerfile" | tail -1)
nginx_pin=$(grep -m1 'image:.*nginx' "$(dirname "$dockerfile")/docker-compose.yml" | sed 's/.*NGINX_IMAGE:-//; s/}.*//')
echo "node base:  $node_pin"
echo "nginx base: $nginx_pin"
echo
echo "Both are pinned by digest, so a rebuilt tag will not be picked up on its own."
echo "To move to the current content of the tag:"
echo "  sudo docker pull node:24-bookworm-slim"
echo "  sudo docker inspect --format '{{index .RepoDigests 0}}' node:24-bookworm-slim"
echo "  # paste the new sha256 into ARG NODE_IMAGE in Dockerfile (same for NGINX_IMAGE)"

if [ "$status_all" -eq 1 ]; then
  echo
  echo "A package crossed a major version. OpenCode's major bumps have changed the"
  echo "config schema and the plugin API before; read README before bumping those."
fi
