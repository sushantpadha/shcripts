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

STEP="checking server is stopped"
if ssh "$REMOTE" "pgrep -u \"\$(id -u)\" java >/dev/null"; then
    echo "WARNING: a java process is running on the server. Restoring under a live server corrupts the world."
    read -rp "Restore anyway? [y/N] " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0
fi

read -rp "Continue? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

echo "==> Copying selected backup to server..."
STEP="copying backup to server"
LEFT="partial /tmp/$ARCHIVE may exist on server - rm it (current worlds untouched)"
scp "$BACKUP_DIR/$ARCHIVE" "$REMOTE:/tmp/$ARCHIVE"
ssh "$REMOTE" "tar -tzf '/tmp/$ARCHIVE' >/dev/null"

echo "==> Finding backup number..."
STEP="finding backup number"
N=0
while ssh "$REMOTE" "test -f '$REMOTE_DIR/${WORLD}.bak-$N.tgz'"; do
    N=$((N+1))
done
REMOTE_BACKUP="$REMOTE_DIR/${WORLD}.bak-$N.tgz"

echo "==> Saving current worlds to $REMOTE_BACKUP..."
STEP="saving current worlds on server"
LEFT="$REMOTE_BACKUP may be incomplete - rm it (current worlds untouched)
/tmp/$ARCHIVE still on server - rm it"
# only archive dims that exist; set -e so a failed tar stops before any rm
ssh "$REMOTE" "
    set -e
    cd '$REMOTE_DIR'
    dirs=''
    for d in '$WORLD' '${WORLD}_nether' '${WORLD}_the_end'; do [ -d \"\$d\" ] && dirs=\"\$dirs \$d\"; done
    if [ -n \"\$dirs\" ]; then
        tar -czf '$REMOTE_BACKUP' \$dirs
        tar -tzf '$REMOTE_BACKUP' >/dev/null
    fi
"

echo "==> Replacing worlds..."
STEP="deleting current worlds and extracting backup"
LEFT="worlds in $REMOTE_DIR may be DELETED or PARTLY extracted
old worlds saved in $REMOTE_BACKUP (if they existed)
backup to restore is in /tmp/$ARCHIVE on server"
ssh "$REMOTE" "
    set -e
    cd '$REMOTE_DIR'
    rm -rf '$WORLD' '${WORLD}_nether' '${WORLD}_the_end'
    tar -xzf '/tmp/$ARCHIVE'
    rm -f '/tmp/$ARCHIVE'
"

LEFT=""
echo "==> Restore complete. Old worlds: $REMOTE_BACKUP"
