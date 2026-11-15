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

# `sh` cannot parse an unquoted value with spaces, and compose can. Say so
# instead of reporting the variable as missing.
if ! ( set -a; . ./.env ) 2>/dev/null; then
  printf '.env has a line sh cannot parse; quote values that contain spaces\n'
  exit 1
fi
set -a
# shellcheck disable=SC1091
. ./.env
set +a

check_password() {
  [ -n "${OPENCODE_PASSWORD:-}" ] || { printf 'OPENCODE_PASSWORD is empty in .env\n'; exit 1; }
  [ "$OPENCODE_PASSWORD" != change-me ] || { printf "OPENCODE_PASSWORD is still 'change-me' in .env\n"; exit 1; }
  return 0
}

check_paths() {
  [ -n "${HOST_HOME:-}" ] || { printf 'HOST_HOME is missing in .env\n'; exit 1; }
  [ -n "${PROJECTS_DIR:-}" ] || { printf 'PROJECTS_DIR is missing in .env\n'; exit 1; }
  case $PROJECTS_DIR in
    /*) ;;
    *) printf "PROJECTS_DIR must be an absolute path (got '%s')\n" "$PROJECTS_DIR"; exit 1 ;;
  esac
  [ "$PROJECTS_DIR" != / ] || { printf 'PROJECTS_DIR must not be / — that mounts the whole host\n'; exit 1; }
  [ "$PROJECTS_DIR" != "$HOST_HOME" ] || { printf 'PROJECTS_DIR is HOST_HOME itself; use a child directory\n'; exit 1; }
  if [ ! -d "$PROJECTS_DIR" ]; then
    printf 'PROJECTS_DIR (%s) does not exist yet\n' "$PROJECTS_DIR"
    exit 2
  fi
  [ -w "$PROJECTS_DIR" ] || { printf 'PROJECTS_DIR (%s) is not writable by %s\n' "$PROJECTS_DIR" "$(id -un)"; exit 1; }
  return 0
}

case ${1:-all} in
  password) check_password ;;
  paths) check_paths ;;
  all)
    check_password
    status=0
    check_paths || status=$?
    exit "$status"
    ;;
  *)
    printf 'usage: check-env.sh [password|paths|all]\n' >&2
    exit 1
    ;;
esac
