#!/bin/bash
# Make an 8G swapfile on / (ext4 NVMe) and enable it at boot.
# Run: sudo bash setup-swap.sh
set -euo pipefail

F=/swapfile
SIZE=8G

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ -e "$F" ] && { echo "$F already exists, stopping"; exit 1; }

# 1. back up fstab first
cp -a /etc/fstab "/etc/fstab.bak.$(date +%F-%H%M%S)"

# 2. create swapfile
fallocate -l "$SIZE" "$F"
chmod 600 "$F"
mkswap "$F"
swapon --priority 10 "$F"

# 3. add fstab line only if not already there
grep -qE "^$F[[:space:]]" /etc/fstab || \
  echo "$F none swap sw,pri=10,nofail 0 0" >> /etc/fstab

# 4. warn only (old unrelated fstab lines also trigger this); backup from step 1 is the rollback
findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1 || echo "fstab check has warnings, review: findmnt --verify"

# 5. turn off the slow loop-image swap (file is kept, delete it yourself later)
swapoff /mnt/linuxdata/swapfile 2>/dev/null || true

swapon --show
free -h | grep -i swap
