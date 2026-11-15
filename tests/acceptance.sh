#!/usr/bin/env bash
# Acceptance suite for the OpenCode container. Run as: sudo bash tests/acceptance.sh
set -uo pipefail

cd "$(dirname "$0")/.."
PASS=0; FAIL=0; MANUAL=0
HOST_UID="${SUDO_UID:-$(id -u)}"; HOST_GID="${SUDO_GID:-$(id -g)}"

ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
man()  { echo "MANUAL $1"; MANUAL=$((MANUAL+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# 1. non-root uid matching the host
uid_inside="$(docker compose exec -T opencode id -u 2>/dev/null | tr -d '\r')"
[ "$uid_inside" = "$HOST_UID" ] && ok "1: uid $uid_inside matches host" || bad "1: uid '$uid_inside' != $HOST_UID"

# 2. no ~/.ssh, and no gateway credentials inside the container at all
docker compose exec -T opencode sh -c 'ls /home/dev/.ssh' >/dev/null 2>&1 && bad "2a: /home/dev/.ssh is visible" || ok "2a: no ~/.ssh"
nkeys="$(docker compose exec -T opencode sh -c 'ls -A /home/dev/.secrets 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')"
[ "$nkeys" = "0" ] && ok "2b: no key files in the container" || bad "2b: $nkeys files in ~/.secrets"

# 3. providers the overlay dropped (their key file is not mounted) must be
#    absent from the *running* server too, not just from the overlay file
api() { docker compose exec -T opencode sh -c "curl -s -u \"opencode:\$OPENCODE_PASSWORD\" http://127.0.0.1:4097$1" 2>/dev/null; }
dropped_ids="$(docker compose logs opencode 2>/dev/null | tr -d '\r' | sed -n 's/.*dropped providers[^:]*: //p' | tail -1)"
if [ -z "$dropped_ids" ]; then
  ok "3: no provider dropped (every referenced key file resolves)"
else
  prov_ids="$(api /api/provider | tr -d '\r' | grep -o '"id":"[^"]*"' | sed 's/.*:"//; s/"$//' | tr '\n' ' ')"
  leftover=""
  for id in $(printf '%s' "$dropped_ids" | tr ',' ' '); do
    case " $prov_ids " in *" $id "*) leftover="$leftover $id";; esac
  done
  [ -z "$leftover" ] && ok "3: dropped providers absent from the running server" || bad "3: dropped provider(s) still registered:$leftover"
fi

# 3b. a host-only MCP server must not reach the running server either
mcp_names="$(api /api/mcp | tr -d '\r' | grep -o '"name":"[^"]*"' | tr '\n' ' ')"
case "$mcp_names" in
  *browse*) bad "3b: browse MCP reached the running server ($mcp_names)";;
  *) ok "3b: no browse MCP in the running server";;
esac

# 4. the host config file is read-only even for an interpreter, and no config
#    file sits in the container's global config directory
docker compose exec -T opencode python3 -c "open('/home/dev/host-config/opencode.jsonc','a').write('')" >/dev/null 2>&1 \
  && bad "4a: host config file is writable" || ok "4a: host config file is read-only"
stray="$(docker compose exec -T opencode sh -c 'ls /home/dev/.config/opencode/opencode.json /home/dev/.config/opencode/opencode.jsonc 2>/dev/null | wc -l' 2>/dev/null | tr -d '\r')"
[ "$stray" = "0" ] && ok "4b: no config file in the global config dir" || bad "4b: global config dir holds $stray config file(s)"

# 5-6. no privilege escalation tools
docker compose exec -T opencode sh -c 'command -v sudo' >/dev/null 2>&1 && bad "5: sudo present" || ok "5: no sudo"
docker compose exec -T opencode sh -c 'command -v docker' >/dev/null 2>&1 && bad "6: docker present" || ok "6: no docker CLI"

# 7. nginx answers 401 unauthenticated on both stacks
code4="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/info)"
code6="$(curl -g -s -o /dev/null -w '%{http_code}' http://[::1]:8080/api/info)"
[ "$code4" = "401" ] && ok "7a: ipv4 401" || bad "7a: ipv4 $code4"
[ "$code6" = "401" ] && ok "7b: ipv6 401" || bad "7b: ipv6 $code6"

# 8-9. human checks
man "8: desktop app connects via pairing link and lists sessions"
man "9: web UI loads at http://opencode.localhost:8080 with no CSP report-only violations"

# 10. the baked policy is root-owned and unmodifiable
owner="$(docker compose exec -T opencode stat -c '%U:%a' /etc/opencode/opencode.json 2>/dev/null | tr -d '\r')"
[ "$owner" = "root:644" ] && ok "10a: /etc policy root:644" || bad "10a: /etc policy is $owner"
docker compose exec -T opencode python3 -c "open('/etc/opencode/opencode.json','a').write('')" >/dev/null 2>&1 \
  && bad "10b: /etc policy writable" || ok "10b: /etc policy read-only"

# 11. files created in /work belong to the host user
docker compose exec -T opencode sh -c 'touch /work/.acceptance-uid && stat -c "%u:%g" /work/.acceptance-uid' > /tmp/.acc-uid 2>/dev/null
read_uid="$(tr -d '\r' < /tmp/.acc-uid)"
[ "$read_uid" = "$HOST_UID:$HOST_GID" ] && ok "11: /work file owned $read_uid" || bad "11: /work file owned '$read_uid'"
docker compose exec -T opencode rm -f /work/.acceptance-uid >/dev/null 2>&1

# 11b. /work is exactly PROJECTS_DIR — not some other host tree
want_work="$(sed -n 's/^PROJECTS_DIR=//p' .env | tail -1)"
got_work="$(docker inspect "$(docker compose ps -q opencode)" \
  --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}' 2>/dev/null | tr -d '\r')"
if [ -n "$want_work" ] && [ "$want_work" = "$got_work" ]; then
  ok "11b: /work is $got_work"
else
  bad "11b: /work is '$got_work', expected PROJECTS_DIR='$want_work'"
fi

# 12. a usable provider credential is stored in the container
# `auth list --format json` is an array of {id,name,connections:[...]};
# a stored credential is one entry inside a `connections` array.
cred="$(docker compose exec -T opencode opencode auth list --format json 2>/dev/null | tr -d '\r' \
  | jq -e '[.[] | .connections[]?] | length > 0' 2>/dev/null)"
[ "$cred" = "true" ] && ok "12: a provider credential is stored" || bad "12: no provider credential stored"

# 13. the JS/TS toolchain resolves inside the running container
tc="$(docker compose exec -T opencode sh -c 'printf "%s|%s|%s" "$(node -v)" "$(pnpm -v)" "$(yarn -v)"' 2>/dev/null | tr -d '\r')"
case "$tc" in
  v2[4-9]*|12.*|1.22.*) ok "13: toolchain $tc" ;;
  *) bad "13: toolchain '$tc' (want node v24+, pnpm 12.x, yarn 1.22.x)" ;;
esac

# 17. the kernel refuses escape primitives (seccomp profile applied)
# /proc/self/status separates the field with a tab, so compare the values only.
seccomp_mode="$(docker compose exec -T opencode sh -c 'grep "^Seccomp:" /proc/self/status' 2>/dev/null | tr -d '\r' | awk '{print $2}')"
case "$seccomp_mode" in
  2) ok "17a: seccomp filter is active (mode 2)" ;;
  "") bad "17a: could not read the seccomp mode" ;;
  *) bad "17a: seccomp mode is $seccomp_mode (want 2)" ;;
esac
probe="$(docker compose exec -T opencode python3 -c \
  'import ctypes; l=ctypes.CDLL(None, use_errno=True); r=l.ptrace(0,0,0,0); print(r, ctypes.get_errno())' \
  2>/dev/null | tr -d '\r')"
[ "$probe" = "-1 1" ] && ok "17b: ptrace refused with EPERM" || bad "17b: ptrace probe '$probe' (want '-1 1')"

# 18. the image is immutable at runtime; only mounted paths accept writes
docker compose exec -T opencode sh -c 'touch /.acceptance-ro' >/dev/null 2>&1 \
  && bad "18a: the root filesystem is writable" || ok "18a: root filesystem is read-only"
docker compose exec -T opencode sh -c 'touch "${HOME}/.config/.acceptance-rw"' >/dev/null 2>&1 \
  && ok "18b: the config dir is writable" || bad "18b: the config dir is not writable"
docker compose exec -T opencode sh -c 'rm -f "${HOME}/.config/.acceptance-rw"; touch "${HOME}/.local/state/.acceptance-rw"' >/dev/null 2>&1 \
  && ok "18c: the state dir is writable" || bad "18c: the state dir is not writable"
# The server signs sessions with a secret kept here. On tmpfs it disappeared at
# every recreate and the desktop app silently lost its pairing.
state_type="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/dev/.local/state"}}{{.Type}}{{end}}{{end}}' "$(docker compose ps -q opencode)" 2>/dev/null)"
[ "$state_type" = "volume" ] \
  && ok "18d: the state dir is a volume (pairing survives recreate)" \
  || bad "18d: the state dir is '$state_type', not a volume"

# 19. both images are pinned by digest, not by a movable tag
node_ref="$(sed -n 's/^ARG NODE_IMAGE=//p' Dockerfile | tail -1)"
case "$node_ref" in
  *@sha256:*) ok "19a: node base pinned (${node_ref##*@})" ;;
  *) bad "19a: node base is not digest-pinned: '$node_ref'" ;;
esac
nginx_ref="$(grep -m1 'image:.*nginx' docker-compose.yml)"
case "$nginx_ref" in
  *@sha256:*) ok "19b: nginx image pinned" ;;
  *) bad "19b: nginx image is not digest-pinned: $nginx_ref" ;;
esac

# 19c. the running image carries the policy this tree defines
want="$(sha256sum policy/opencode.json | cut -d' ' -f1)"
got="$(docker image inspect -f '{{index .Config.Labels "org.opencode-docker.policy-sha"}}' opencode-docker-opencode:local 2>/dev/null || true)"
[ "$got" = "$want" ] \
  && ok "19c: image carries the current policy digest" \
  || bad "19c: image policy digest is '${got:-none}', tree has $want (run: oc up --build)"

echo
[ "$FAIL" -eq 0 ]
