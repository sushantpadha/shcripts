#!/bin/bash
# Back up a Minecraft world from the server to a local .tar.gz (optional arg: world name)
# ASSUMES PAPER/SPIGOT LAYOUT: <world>, <world>_nether, <world>_the_end. Missing folders are skipped.
set -e
source "$(dirname "${BASH_SOURCE[0]}")/../../utils/app/common.sh"

[ $# -le 1 ] || { echo "Usage: $0 [world-name]"; exit 1; }
WORLD="${1:-world}"
mkdir -p "$BACKUP_DIR"

layout_warning

STEP="looking for worlds on the server"
mapfile -t DIRS < <(world_dirs "$WORLD")
[ ${#DIRS[@]} -gt 0 ] || { echo -e "${RED}No '$WORLD' folder in $REMOTE_DIR on $REMOTE.${RST}"; exit 1; }
for d in "$WORLD" "${WORLD}_nether" "${WORLD}_the_end"; do
    [[ " ${DIRS[*]} " == *" $d "* ]] || warn "$d not on the server, skipped"
done

if [ $# -eq 0 ]; then
    echo "Backup configuration:"
    echo "  Server:      $REMOTE"
    echo "  Directory:   $REMOTE_DIR"
    echo "  Folders:     ${DIRS[*]}"
    echo "  Staging dir: $REMOTE_TMP (on the server)"
    echo "  Destination: $BACKUP_DIR"
    echo
    confirm "Back up?" || exit 0
fi

ARCHIVE="${WORLD}-$(date +%Y%m%d-%H%M%S).tar.gz"
REMOTE_ARCHIVE="$REMOTE_TMP/$ARCHIVE"

STEP="checking free space"
# world files are already compressed, so the archive is about as big as the raw folders
need_space "$REMOTE_TMP" "$(remote_bytes "${DIRS[@]}")" "the archive"

echo "==> Creating archive on server..."
STEP="creating archive on server"
LEFT="$REMOTE_ARCHIVE (maybe partial) - rm it"
ssh "$REMOTE" "tar -czf '$REMOTE_ARCHIVE' -C '$REMOTE_DIR' $(quote_list "${DIRS[@]}")"

echo "==> Copying backup to laptop..."
STEP="copying backup to laptop"
LEFT="$REMOTE_ARCHIVE - rm it
local $BACKUP_DIR/$ARCHIVE may be partial - check/delete it"
scp "$REMOTE:$REMOTE_ARCHIVE" "$BACKUP_DIR/$ARCHIVE"

echo "==> Cleaning up remote archive..."
STEP="cleaning up remote archive"
LEFT="$REMOTE_ARCHIVE - rm it (backup itself is fine locally)"
ssh "$REMOTE" "rm -f '$REMOTE_ARCHIVE'"

LEFT=""
echo -e "${GRN}==> Backup complete: $BACKUP_DIR/$ARCHIVE${RST}"
