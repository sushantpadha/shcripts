#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/../../.env"
set +a

REMOTE="$APP_SSH_USER@$APP_SSH_HOST"
REMOTE_DIR="$APP_REMOTE_DIR"
DEST="$APP_BACKUP_DIR"
WORLD="${1:-world}"

mkdir -p "$DEST"

if [ $# -eq 0 ]; then
    echo "Backup configuration:"
    echo "  Server: $REMOTE"
    echo "  Directory: $REMOTE_DIR"
    echo "  World: $WORLD"
    echo "  Dimensions: ${WORLD}, ${WORLD}_nether, ${WORLD}_the_end"
    echo "  Destination: $DEST"
    echo
    echo "Type enter to backup or Ctrl+C"
    read -p "---" user_input___
elif [ $# -gt 1 ]; then
    echo "Usage: $0 [world-name]"
    exit 1
fi

ARCHIVE="${WORLD}-$(date +%Y%m%d-%H%M%S).tar.gz"
REMOTE_ARCHIVE="/tmp/$ARCHIVE"

echo "==> Creating archive on server..."
ssh "$REMOTE" "tar -czf '$REMOTE_ARCHIVE' -C '$REMOTE_DIR' '$WORLD' '${WORLD}_nether' '${WORLD}_the_end'"

echo "==> Copying backup to laptop..."
scp "$REMOTE:$REMOTE_ARCHIVE" "$DEST/$ARCHIVE"

echo "==> Cleaning up remote archive..."
ssh "$REMOTE" "rm -f '$REMOTE_ARCHIVE'"

echo "==> Backup complete: $DEST/$ARCHIVE"

