#!/bin/sh
# One place for the .env rules. `oc config`, `oc doctor` and `setup.sh` all
# call this, so an install cannot pass one gate and fail another.
#
#   check-env.sh password   exit 0 ok, 1 with the reason on stdout
#   check-env.sh paths      exit 0 ok, 2 warning, 1 with the reason
#   check-env.sh all        the worst of the two (default)
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"

[ -f .env ] || { printf 'no .env — run ./setup.sh\n'; exit 1; }

# Read one value without sourcing the file: compose accepts `KEY=my dir`, and
# `sh` would treat that as a command. Quoted values are unquoted here.
env_get() {
  value=$(awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' .env)
  case $value in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s\n' "$value"
}

env_has() {
  grep -q "^$1=" .env
}

check_password() {
  env_has OPENCODE_PASSWORD || { printf 'OPENCODE_PASSWORD is missing in .env\n'; exit 1; }
  password=$(env_get OPENCODE_PASSWORD)
  [ -n "$password" ] || { printf 'OPENCODE_PASSWORD is empty in .env\n'; exit 1; }
  [ "$password" != change-me ] || { printf "OPENCODE_PASSWORD is still 'change-me' in .env\n"; exit 1; }
  return 0
}

check_paths() {
  env_has HOST_HOME || { printf 'HOST_HOME is missing in .env\n'; exit 1; }
  host_home=$(env_get HOST_HOME)
  [ -n "$host_home" ] || { printf 'HOST_HOME is empty in .env\n'; exit 1; }

  env_has PROJECTS_DIR || { printf 'PROJECTS_DIR is missing in .env\n'; exit 1; }
  projects=$(env_get PROJECTS_DIR)
  [ -n "$projects" ] || { printf 'PROJECTS_DIR is empty in .env\n'; exit 1; }

  case $projects in
    /*) ;;
    *) printf "PROJECTS_DIR must be an absolute path (got '%s')\n" "$projects"; exit 1 ;;
  esac
  [ "$projects" != / ] || { printf 'PROJECTS_DIR must not be / — that mounts the whole host\n'; exit 1; }
  [ "$projects" != "$host_home" ] || { printf 'PROJECTS_DIR is HOST_HOME itself; use a child directory\n'; exit 1; }
  # `sudo oc` would otherwise check root's home, not the one compose mounts.
  [ "$projects" != "/root" ] || { printf 'PROJECTS_DIR must not be /root\n'; exit 1; }
  if [ ! -d "$projects" ]; then
    printf 'PROJECTS_DIR (%s) does not exist yet\n' "$projects"
    exit 2
  fi
  [ -w "$projects" ] || {
    printf 'PROJECTS_DIR (%s) is not writable by %s\n' "$projects" "$(id -un)"
    exit 1
  }
  return 0
}

case ${1:-all} in
  password) check_password ;;
  paths) check_paths ;;
  get) env_get "${2:?usage: check-env.sh get NAME}" ;;
  all)
    check_password
    status=0
    check_paths || status=$?
    exit "$status"
    ;;
  *)
    printf 'usage: check-env.sh [password|paths|all|get NAME]\n' >&2
    exit 1
    ;;
esac
