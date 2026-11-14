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

mkdir -p "$HOME/projects" "$HOME/.config/opencode"

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
chmod 600 .env

if grep -qE '^OPENCODE_PASSWORD=(change-me)?$' .env; then
  echo "error: .env has an empty or example OPENCODE_PASSWORD; set a real one" >&2
  exit 1
fi
if [ ! -f "$HOME/.config/opencode/opencode.jsonc" ] && [ ! -f "$HOME/.config/opencode/opencode.json" ]; then
  echo "note: no host OpenCode config found; the container starts with a minimal one"
fi

echo "password: .env (OPENCODE_PASSWORD)"
echo "next:"
echo "  sudo docker compose build"
echo "  sudo docker compose up -d"
echo "  sudo docker compose exec opencode opencode pair --url http://opencode.localhost:8080"
