#!/bin/bash
# Restore a local world backup onto the server (current worlds are saved on the server first)
# ASSUMES PAPER/SPIGOT LAYOUT: <world>, <world>_nether, <world>_the_end. Missing folders are skipped.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/../../utils/app/common.sh"

layout_warning

echo "Available backups:"
ls -1 "$BACKUP_DIR"
echo

read -rp "Enter backup filename to restore: " ARCHIVE
[ -f "$BACKUP_DIR/$ARCHIVE" ] || { echo -e "${RED}Error: backup not found.${RST}"; exit 1; }

WORLD="${ARCHIVE%-????????-??????.tar.gz}"
[ "$WORLD" != "$ARCHIVE" ] || { echo -e "${RED}Error: could not determine world name from archive.${RST}"; exit 1; }

STEP="reading the backup and the server"
IN_BACKUP=$(tar -tzf "$BACKUP_DIR/$ARCHIVE" | cut -d/ -f1 | sort -u | tr '\n' ' ')
mapfile -t HAVE < <(world_dirs "$WORLD")
echo "World:                    $WORLD"
echo "Backup contains:          $IN_BACKUP"
echo "Removed from the server:  ${HAVE[*]:-nothing (no current worlds)}  (saved to $WORLD.bak-N.tgz first)"
echo

STEP="checking the server is stopped"
procs=$(ssh "$REMOTE" "pgrep -a -- '$SERVER_PROC' || true")
if [ -n "$procs" ]; then
    warn "a process named '$SERVER_PROC' is running on the server:"
    echo "$procs"
fi
confirm "Is the Minecraft server STOPPED? (restoring under a live server corrupts the world)" || exit 0
confirm "Replace the worlds on $REMOTE with $ARCHIVE?" || exit 0

STEP="checking free space"
need_space "$REMOTE_TMP" "$(stat -c %s "$BACKUP_DIR/$ARCHIVE")" "uploading the backup"
[ ${#HAVE[@]} -eq 0 ] || need_space "$REMOTE_DIR" "$(remote_bytes "${HAVE[@]}")" "saving the current worlds"

echo "==> Copying selected backup to server..."
STEP="copying backup to server"
LEFT="partial $REMOTE_TMP/$ARCHIVE may exist on server - rm it (current worlds untouched)"
scp "$BACKUP_DIR/$ARCHIVE" "$REMOTE:$REMOTE_TMP/$ARCHIVE"
ssh "$REMOTE" "tar -tzf '$REMOTE_TMP/$ARCHIVE' >/dev/null"

echo "==> Finding backup number..."
STEP="finding backup number"
N=0
while ssh "$REMOTE" "test -f '$REMOTE_DIR/${WORLD}.bak-$N.tgz'"; do
    N=$((N+1))
done
REMOTE_BACKUP="$REMOTE_DIR/${WORLD}.bak-$N.tgz"

if [ ${#HAVE[@]} -gt 0 ]; then
    echo "==> Saving current worlds to $REMOTE_BACKUP..."
    STEP="saving current worlds on server"
    LEFT="$REMOTE_BACKUP may be incomplete - rm it (current worlds untouched)
$REMOTE_TMP/$ARCHIVE still on server - rm it"
    # set -e so a failed tar stops before any rm
    ssh "$REMOTE" "
        set -e
        cd '$REMOTE_DIR'
        tar -czf '$REMOTE_BACKUP' $(quote_list "${HAVE[@]}")
        tar -tzf '$REMOTE_BACKUP' >/dev/null
    "
fi

echo "==> Replacing worlds..."
STEP="deleting current worlds and extracting backup"
LEFT="worlds in $REMOTE_DIR may be DELETED or PARTLY extracted
old worlds saved in $REMOTE_BACKUP (if they existed)
backup to restore is in $REMOTE_TMP/$ARCHIVE on server"
ssh "$REMOTE" "
    set -e
    cd '$REMOTE_DIR'
    rm -rf '$WORLD' '${WORLD}_nether' '${WORLD}_the_end'
    tar -xzf '$REMOTE_TMP/$ARCHIVE'
    rm -f '$REMOTE_TMP/$ARCHIVE'
"

LEFT=""
echo -e "${GRN}==> Restore complete.${RST} Old worlds: $REMOTE_BACKUP"
