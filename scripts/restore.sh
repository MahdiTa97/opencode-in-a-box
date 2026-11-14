#!/bin/sh
# Verify or restore an oc-data backup.
#   ./scripts/restore.sh --check <archive>   # integrity only, changes nothing
#   ./scripts/restore.sh <archive>           # replaces the live volume contents
set -eu
cd "$(dirname "$0")/.."

mode=restore
if [ "${1:-}" = "--check" ]; then
  mode=check
  shift
fi
archive="${1:-}"
[ -n "$archive" ] || { echo "usage: $0 [--check] <archive.tar.gz>" >&2; exit 1; }
[ -f "$archive" ] || { echo "no such archive: $archive" >&2; exit 1; }

dir="$(cd "$(dirname "$archive")" && pwd)"
base="$(basename "$archive")"

case "$mode" in
  check)
    sudo docker compose run --rm --no-deps --user root --entrypoint sh \
      -v "$dir:/backup:ro" opencode -c \
      "gzip -t /backup/$base && tar tzf /backup/$base | head -5 && echo 'archive is readable'"
    ;;
  restore)
    uid="${SUDO_UID:-$(id -u)}"
    gid="${SUDO_GID:-$(id -g)}"
    echo "stopping the container before restoring $base"
    sudo docker compose stop opencode
    sudo docker compose run --rm --no-deps --user root --entrypoint sh \
      -v "$dir:/backup:ro" opencode -c \
      "find /home/dev/.local/share/opencode -mindepth 1 -delete 2>/dev/null || true; tar xzf /backup/$base -C /home/dev/.local/share/opencode; chown -R $uid:$gid /home/dev/.local/share/opencode"
    echo "starting the container on the restored data"
    sudo docker compose up -d --force-recreate
    echo "restored $base; check with: sudo bash tests/acceptance.sh"
    ;;
esac
