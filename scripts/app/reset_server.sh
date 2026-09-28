#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "$SCRIPT_DIR/../../.env"
set +a

# reuse one ssh connection (login once, persists 10m after last use)
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=${XDG_RUNTIME_DIR:-/tmp}/shcripts-ssh-%C" -o ControlPersist=10m)
ssh() { command ssh "${SSH_OPTS[@]}" "$@"; }
scp() { command scp "${SSH_OPTS[@]}" "$@"; }

REMOTE="$APP_SSH_USER@$APP_SSH_HOST"
REMOTE_DIR="$APP_REMOTE_DIR"
BACKUP_DIR="$APP_BACKUP_DIR"

# on any exit: report failure (+ what is left on server), then close ssh master
STEP="startup checks"
LEFT=""
finish() {
    rc=$?
    trap - EXIT
    if [ $rc -ne 0 ]; then
        echo
        echo "FAILED (exit $rc) during: $STEP"
        if [ -n "$LEFT" ]; then
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            echo "! NEEDS ATTENTION - left behind on $REMOTE:"
            printf '%s\n' "$LEFT" | sed 's/^/! /'
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        fi
    fi
    ssh -O exit "$REMOTE" 2>/dev/null || true
}
trap finish EXIT

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
STEP="finding backup number"

declare -i N=0

echo "command is: ssh \"$REMOTE\" \"test -f '$REMOTE_DIR/${WORLD}.bak-$N.tgz'\""
while ssh "$REMOTE" "test -f '$REMOTE_DIR/${WORLD}.bak-$N.tgz'"; do
    echo "tried $N"
    N=$((N+1))
done

REMOTE_BACKUP="$REMOTE_DIR/${WORLD}.bak-$N.tgz"

echo "==> Moving existing worlds to $REMOTE_BACKUP..."
STEP="archiving + deleting current worlds on server"
LEFT="$REMOTE_BACKUP may be incomplete
current worlds in $REMOTE_DIR may be PARTLY or FULLY DELETED - check before starting server"

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
STEP="copying backup to server"
LEFT="worlds are DELETED from $REMOTE_DIR, restore NOT done
old worlds saved in $REMOTE_BACKUP
partial /tmp/$ARCHIVE may exist"

scp "$BACKUP_DIR/$ARCHIVE" "$REMOTE:/tmp/$ARCHIVE"

echo "==> Extracting backup..."
STEP="extracting backup on server"
LEFT="worlds in $REMOTE_DIR may be PARTIALLY extracted
/tmp/$ARCHIVE still on server - rm it
old worlds saved in $REMOTE_BACKUP"

ssh "$REMOTE" "
    tar -xzf '/tmp/$ARCHIVE' -C '$REMOTE_DIR'
    rm -f '/tmp/$ARCHIVE'
"

LEFT=""
echo "==> Restore complete."

