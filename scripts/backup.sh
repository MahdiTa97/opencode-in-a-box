#!/bin/sh
# Back up the oc-data volume: sessions, credentials, and snapshots.
# Usage: ./scripts/backup.sh [destination-directory]
set -eu
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "no .env here; run ./setup.sh first" >&2; exit 1; }

dest="${1:-$PWD/backups}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"
name="oc-data-$stamp.tar.gz"

# Run inside the project's own image: nothing extra to pull, and the volume is
# already mounted at the same path there.
sudo docker compose run --rm --no-deps --user root --entrypoint sh \
  -v "$dest:/backup" \
  opencode -c "umask 077; tar czf /backup/$name -C /home/dev/.local/share/opencode ."

chmod 600 "$dest/$name"
size="$(du -h "$dest/$name" | cut -f1)"
echo "wrote $dest/$name ($size)"
echo "verify it with: ./scripts/restore.sh --check $dest/$name"
