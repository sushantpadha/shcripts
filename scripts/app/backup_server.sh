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
DEST="$APP_BACKUP_DIR"
WORLD="${1:-world}"

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
STEP="creating archive on server"
LEFT="$REMOTE_ARCHIVE (maybe partial) - rm it"
ssh "$REMOTE" "tar -czf '$REMOTE_ARCHIVE' -C '$REMOTE_DIR' '$WORLD' '${WORLD}_nether' '${WORLD}_the_end'"

echo "==> Copying backup to laptop..."
STEP="copying backup to laptop"
LEFT="$REMOTE_ARCHIVE - rm it
local $DEST/$ARCHIVE may be partial - check/delete it"
scp "$REMOTE:$REMOTE_ARCHIVE" "$DEST/$ARCHIVE"

echo "==> Cleaning up remote archive..."
STEP="cleaning up remote archive"
LEFT="$REMOTE_ARCHIVE - rm it (backup itself is fine locally)"
ssh "$REMOTE" "rm -f '$REMOTE_ARCHIVE'"

LEFT=""
echo "==> Backup complete: $DEST/$ARCHIVE"

