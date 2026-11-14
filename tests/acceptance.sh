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

# 2. no ~/.ssh, only the two key files
docker compose exec -T opencode sh -c 'ls /home/dev/.ssh' >/dev/null 2>&1 && bad "2a: /home/dev/.ssh is visible" || ok "2a: no ~/.ssh"
nkeys="$(docker compose exec -T opencode sh -c 'ls /home/dev/.secrets | wc -l' 2>/dev/null | tr -d '\r')"
[ "$nkeys" = "2" ] && ok "2b: exactly 2 key files mounted" || bad "2b: $nkeys files in ~/.secrets"

# 3. the accepted trade-off: key is readable inside
check "3: key readable by the agent (accepted risk)" \
  "docker compose exec -T opencode python3 -c \"print(len(open('/home/dev/.secrets/gateway.key').read()))\""

# 4. config file is read-only even for an interpreter
docker compose exec -T opencode python3 -c "open('/home/dev/.config/opencode/opencode.jsonc','a').write('')" >/dev/null 2>&1 \
  && bad "4: config file is writable" || ok "4: config file is read-only"

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

# 12. egress to the provider endpoint works
code="$(docker compose exec -T opencode curl -s -o /dev/null -w '%{http_code}' https://llm.example.com/v1/models 2>/dev/null)"
[ -n "$code" ] && [ "$code" != "000" ] && ok "12: provider reachable (HTTP $code)" || bad "12: provider unreachable"

echo
echo "passed=$PASS failed=$FAIL manual=$MANUAL"
[ "$FAIL" -eq 0 ]
