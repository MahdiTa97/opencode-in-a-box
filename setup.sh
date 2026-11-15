#!/bin/sh
# One-time setup on a new machine, and a safe repair for an old .env.
# Run it from the repo root:  ./setup.sh
set -eu
cd "$(dirname "$0")"

command -v docker >/dev/null 2>&1 || {
  echo "docker is required: https://docs.docker.com/engine/install/" >&2
  exit 1
}
docker compose version >/dev/null 2>&1 || {
  echo "docker compose v2 ('docker compose', not 'docker-compose') is required" >&2
  exit 1
}

# Say what this machine can and cannot do before a ten-minute build finds out.
preflight() { printf '  %-22s %s\n' "$1" "$2"; }
echo "preflight:"
preflight "compose" "$(docker compose version --short 2>/dev/null || echo unknown)"

if [ -r /proc/self/status ] && grep -q '^Seccomp:' /proc/self/status; then
  preflight "seccomp" "available (the container profile needs it)"
else
  echo "  seccomp                MISSING — the container will not start; this kernel is too old" >&2
  exit 1
fi

if docker info >/dev/null 2>&1; then
  preflight "docker daemon" "reachable without sudo"
elif command -v sudo >/dev/null 2>&1; then
  preflight "docker daemon" "needs sudo (use: sudo docker compose ...)"
else
  preflight "docker daemon" "not reachable — add this user to the docker group first"
fi

if [ -f /proc/net/if_inet6 ] || [ -s /proc/net/if_inet6 ]; then
  preflight "ipv6" "present (http://opencode.localhost resolves to ::1)"
else
  preflight "ipv6" "absent — remove the [::1]:8080 publish from docker-compose.yml"
fi

if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -qE ':8080[[:space:]]'; then
  preflight "port 8080" "in use (fine if it is this project's nginx)"
else
  preflight "port 8080" "free"
fi

if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo unknown)" = "cgroup2fs" ]; then
  preflight "cgroups" "v2"
else
  preflight "cgroups" "v1 or unknown (limits still work, snapshots may differ)"
fi

mkdir -p "$HOME/.config/opencode"

if [ ! -f .env ]; then
  password="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24 || true)"
  [ -n "$password" ] || password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  printf 'OPENCODE_PASSWORD=%s\n' "$password" > .env
  echo "wrote .env"
fi

# Fill anything an older .env is missing, without touching values already set.
add_if_missing() {
  key="$1"
  value="$2"
  grep -q "^${key}=" .env 2>/dev/null || printf '%s=%s\n' "$key" "$value" >> .env
}
add_if_missing OPENCODE_PASSWORD "$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24)"
add_if_missing HOST_UID "$(id -u)"
add_if_missing HOST_GID "$(id -g)"
add_if_missing HOST_HOME "$HOME"
add_if_missing PROJECTS_DIR "$HOME/projects"
chmod 600 .env

# PROJECTS_DIR is the only host tree the container can read and write, so a
# careless value here is a real hole. The rules live in scripts/check-env.sh so
# `oc config` and `oc doctor` cannot disagree with this script.
projects_dir="$(sed -n 's/^PROJECTS_DIR=//p' .env | tail -1)"
mkdir -p "$projects_dir" 2>/dev/null || { echo "error: cannot create $projects_dir" >&2; exit 1; }
sh scripts/check-env.sh all || exit 1
case "$projects_dir" in
  "$HOME"/*) ;;
  *) echo "note: PROJECTS_DIR points outside \$HOME ($projects_dir)" ;;
esac

if [ ! -f "$HOME/.config/opencode/opencode.jsonc" ] && [ ! -f "$HOME/.config/opencode/opencode.json" ]; then
  echo "note: no host OpenCode config found; the container starts with a minimal one"
fi

echo "password: .env (OPENCODE_PASSWORD)"
echo "next:"
echo "  ./bin/oc up --build"
echo "  ./bin/oc pair"
echo "  sudo docker compose exec opencode opencode pair --url http://opencode.localhost:8080"
echo ""
echo "afterwards: ./scripts/audit.sh   (what the guardrails blocked)"
