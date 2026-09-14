#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/../../.env"
set +a

REMOTE="$APP_SSH_USER@$APP_SSH_HOST"
REMOTE_DIR="$APP_REMOTE_DIR"
BACKUP_DIR="$APP_BACKUP_DIR"

echo "Available backups:"
ls -1 "$BACKUP_DIR"
echo

read -rp "Enter backup filename to restore: " ARCHIVE

if [ ! -f "$BACKUP_DIR/$ARCHIVE" ]; then
    echo "Error: backup not found."
    exit 1
fi

WORLD="${ARCHIVE%-????????-??????.tar.gz}"

if [ "$WORLD" = "$ARCHIVE" ]; then
    echo "Error: could not determine world name from archive."
    exit 1
fi

echo "World: $WORLD"
echo "Will restore:"
echo "  $WORLD"
echo "  ${WORLD}_nether"
echo "  ${WORLD}_the_end"
echo

read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

echo "==> Finding backup number..."

N=0
while ssh "$REMOTE" "test -f '$REMOTE_DIR/${WORLD}.bak-$N.tgz'"; do
    ((N++))
done

REMOTE_BACKUP="$REMOTE_DIR/${WORLD}.bak-$N.tgz"

echo "==> Moving existing worlds to $REMOTE_BACKUP..."

ssh "$REMOTE" "
    tar -czf '$REMOTE_BACKUP' -C '$REMOTE_DIR' \
        '$WORLD' \
        '${WORLD}_nether' \
        '${WORLD}_the_end' 2>/dev/null || true

    rm -rf '$REMOTE_DIR/$WORLD' \
           '$REMOTE_DIR/${WORLD}_nether' \
           '$REMOTE_DIR/${WORLD}_the_end'
"

echo "==> Copying selected backup to server..."

scp "$BACKUP_DIR/$ARCHIVE" "$REMOTE:/tmp/$ARCHIVE"

echo "==> Extracting backup..."

ssh "$REMOTE" "
    tar -xzf '/tmp/$ARCHIVE' -C '$REMOTE_DIR'
    rm -f '/tmp/$ARCHIVE'
"

echo "==> Restore complete."

