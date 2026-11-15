#!/bin/sh
# Weekly sanity run: is the installation what its files claim, and is there a
# backup that can actually be read back?
#
# Runs as root (the docker socket is root-only), but every step delegates to the
# script or command that already owns it. Nothing here mutates the installation:
# no build, no up, no restore. The one artefact it creates is a backup archive.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

fail=0

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

step() {
  label=$1
  shift
  if [ "$DRY_RUN" = 1 ]; then
    say "would run: $label ($*)"
    return 0
  fi
  if "$@"; then
    say "ok: $label"
  else
    say "FAILED: $label"
    fail=1
  fi
}

# A backup first, so a later failure still leaves a fresh archive behind.
step "backup" sh scripts/backup.sh

latest=$(ls -t backups/oc-data-*.tar.gz 2>/dev/null | head -n 1 || true)
if [ -n "${latest:-}" ]; then
  step "backup is readable" sh scripts/restore.sh --check "$latest"
else
  say "FAILED: no backup archive found in backups/"
  fail=1
fi

step "doctor" ./bin/oc doctor
step "what the guardrails blocked" sh scripts/audit.sh 7d
step "pinned versions" sh scripts/check-updates.sh

[ "$fail" = 0 ] && say "maintenance finished" || say "maintenance finished with failures"
exit "$fail"
