#!/bin/bash
# nuke-and-reinstall-nvidia.sh
# Purpose: Thoroughly remove all NVIDIA components (apt/dkms/runfile/etc),
#         reinstall the recommended Ubuntu driver, and optionally disable dGPU.
#
# Usage:
#   sudo ./nuke-and-reinstall-nvidia.sh        # Purge + reinstall (interactive prompts)
#   sudo ./nuke-and-reinstall-nvidia.sh --yes  # Skip final confirmation
#   sudo ./nuke-and-reinstall-nvidia.sh --disable-after
#
# WARNING: destructive. This removes packages, modules, and config files.
#          Backups are created under /root/nvidia-backup-<timestamp>.tar.gz
# ------------------------------------------------------------

set -u

TS=$(date +%Y%m%d%H%M%S)
BACKUP="/root/nvidia-backup-$TS"
BACKUP_TGZ="$BACKUP.tar.gz"

echo "=== NVIDIA Nuke & Reinstall Script ==="
echo "Backup -> $BACKUP_TGZ"
echo
if [ "$(id -u)" -ne 0 ]; then
  echo "Run me as root: sudo $0"
  exit 1
fi

# Flags
AUTO_YES=false
DISABLE_AFTER=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    --disable-after) DISABLE_AFTER=true ;;
    *) ;;
  esac
done

if [ "$AUTO_YES" = false ]; then
  echo "This will REMOVE NVIDIA drivers/config and then reinstall the recommended driver."
  echo "Backups will be placed at: $BACKUP_TGZ"
  read -p "Type YES to proceed: " answer
  if [ "$answer" != "YES" ]; then
    echo "Cancelled."
    exit 0
  fi
fi

# 0) Create backup of likely NVIDIA config locations
echo
echo "1) Backing up NVIDIA-related config (may include Xorg files, modprobe, udev rules)..."
mkdir -p "$BACKUP"
# Collect files / dirs commonly touched by nvidia installers or packages
paths=(
  /etc/modprobe.d/*nvidia* /etc/modprobe.d/blacklist-nvidia.conf
  /etc/modprobe.d/*nvidia*.conf
  /etc/udev/rules.d/*nvidia* /lib/udev/rules.d/*nvidia*
  /etc/X11/xorg.conf /etc/X11/xorg.conf.d/*nvidia* /usr/share/X11/xorg.conf.d/*nvidia*
  /var/lib/dkms/*nvidia* /var/lib/dkms/*nvidia*
  /usr/src/*nvidia* /lib/modules/*/*nvidia*
  /etc/prime-discrete /etc/alternatives/*nvidia* /etc/modprobe.d/*nvidia*
  /usr/bin/nvidia-uninstall /usr/local/bin/nvidia-uninstall
)
# Use tar-friendly file list
tmpfile="$(mktemp)"
for p in "${paths[@]}"; do
  for f in $p; do
    [ -e "$f" ] && echo "$f" >> "$tmpfile"
  done
done

# Also capture list of installed packages and dkms modules
dpkg --get-selections | grep -i nvidia > "$BACKUP/dpkg-nvidia-packages-$TS.txt" || true
dkms status > "$BACKUP/dkms-status-$TS.txt" || true
lsmod | grep nvidia > "$BACKUP/lsmod-nvidia-$TS.txt" || true
lspci -nnk | grep -i nvidia -A3 > "$BACKUP/lspci-nvidia-$TS.txt" || true

# Create tarball of discovered files
if [ -s "$tmpfile" ]; then
  tar --warning=no-file-changed -czf "$BACKUP_TGZ" -T "$tmpfile" 2>/dev/null || true
else
  echo "(No static files to archive found; still saving package/dkms lists.)"
  tar -czf "$BACKUP_TGZ" "$BACKUP" >/dev/null 2>&1 || true
fi
rm -f "$tmpfile"
echo "Backup created (or attempted): $BACKUP_TGZ"
echo

# 1) Attempt to stop related services gracefully
echo "2) Stopping and masking NVIDIA services..."
systemctl stop nvidia-persistenced.service 2>/dev/null || true
systemctl disable --now nvidia-persistenced.service 2>/dev/null || true
systemctl mask nvidia-persistenced.service 2>/dev/null || true
systemctl stop nvidia-powerd.service 2>/dev/null || true
systemctl disable --now nvidia-powerd.service 2>/dev/null || true
systemctl mask nvidia-powerd.service 2>/dev/null || true
# other possible service names
for s in nvidia-hibernate.service nvidia-resume.service nvidia-suspend.service; do
  systemctl stop "$s" 2>/dev/null || true
  systemctl disable --now "$s" 2>/dev/null || true
  systemctl mask "$s" 2>/dev/null || true
done
echo "Done."
echo

# 2) If runfile installer present, try to run its own uninstallers
echo "3) Looking for NVIDIA runfile uninstallers..."
if [ -x /usr/bin/nvidia-uninstall ]; then
  echo " -> Running /usr/bin/nvidia-uninstall (non-interactive)..."
  /usr/bin/nvidia-uninstall
fi
if [ -x /usr/local/bin/nvidia-uninstall ]; then
  echo " -> Running /usr/local/bin/nvidia-uninstall (non-interactive)..."
  /usr/local/bin/nvidia-uninstall
fi

# 3) Purge apt packages matching nvidia / nvidia-driver / libnvidia / xserver-xorg-video-nvidia etc.
echo "4) Purging NVIDIA-related apt packages (this may remove nvidia-utils, nvidia-driver, libnvidia, etc.)..."
apt-get update -y
# show what would be removed
echo "Packages that match 'nvidia' (will be purged):"
apt-cache pkgnames | grep -i '^nvidia' || true

# Purge common package names (safe to run multiple times)
apt-get purge -y 'nvidia-*' 'libnvidia-*' 'xserver-xorg-video-nvidia*' 'nvidia-driver-*' 'nvidia-utils-*' || true
apt-get autoremove -y
apt-get autoclean -y

# 4) Remove DKMS modules and source directories
echo "5) Removing DKMS modules and /usr/src leftovers..."
dkms_list=$(dkms status 2>/dev/null | grep -i nvidia || true)
if [ -n "$dkms_list" ]; then
    echo "DKMS entries found:"
    echo "$dkms_list"
    # try to remove each DKMS module
    while IFS= read -r line; do
        modname=$(echo "$line" | awk '{print $1}')
        ver=$(echo "$line" | awk '{print $2}')
        if [ -n "$modname" ] && [ -n "$ver" ]; then
            echo " -> dkms remove -m $modname -v $ver --all"
            dkms remove -m "$modname" -v "$ver" --all || true
        fi
    done <<< "$dkms_list"
fi

# Remove /usr/src/nvidia* if present
rm -rf /usr/src/nvidia-* /usr/src/*nvidia* 2>/dev/null || true
rm -rf /var/lib/dkms/*nvidia* 2>/dev/null || true

# 5) Remove leftover kernel modules (best-effort)
echo "6) Removing leftover NVIDIA kernel modules from /lib/modules..."
find /lib/modules -type f -name '*nvidia*' -exec rm -f {} \; 2>/dev/null || true
depmod -a || true

# 6) Remove common NVIDIA config files (udev, modprobe, Xorg)
echo "7) Removing NVIDIA-related config files (udev/modprobe/X11)..."
rm -f /etc/modprobe.d/*nvidia* /etc/modprobe.d/blacklist-nvidia.conf 2>/dev/null || true
rm -f /etc/udev/rules.d/*nvidia* /lib/udev/rules.d/*nvidia* 2>/dev/null || true
rm -f /etc/X11/xorg.conf 2>/dev/null || true
rm -f /etc/X11/xorg.conf.d/*nvidia* /usr/share/X11/xorg.conf.d/*nvidia* 2>/dev/null || true
rm -f /etc/alternatives/*nvidia* 2>/dev/null || true
rm -rf /var/lib/nvidia* /var/log/nvidia* 2>/dev/null || true

# 7) Ensure modprobe blacklist removed (we'll reinstall cleanly)
echo "8) (If any) removing modprobe blacklist entries that might conflict with reinstall..."
# note: we removed all /etc/modprobe.d/*nvidia* above

# 8) Rebuild initramfs and update grub (after purge)
echo "9) Updating initramfs and grub..."
update-initramfs -u || true
if [ -f /etc/default/grub ]; then
  update-grub || true
fi

# 9) Check for Secure Boot
echo "10) Checking Secure Boot state (signing issues can prevent driver load)"
if command -v mokutil >/dev/null 2>&1; then
  SB=$(mokutil --sb-state 2>/dev/null || true)
  echo "$SB"
  if echo "$SB" | grep -iq enabled; then
    echo "NOTE: Secure Boot is ENABLED. After reinstall, unsigned kernel modules may fail to load."
    echo "If you want to use the NVIDIA driver, consider disabling Secure Boot in BIOS or enrolling a MOK key."
  else
    echo "Secure Boot disabled or not present."
  fi
else
  echo "mokutil not found; cannot check Secure Boot."
fi

# 10) Reinstall recommended driver using ubuntu-drivers
echo
echo "11) Installing recommended NVIDIA driver via ubuntu-drivers..."
apt-get update -y
if command -v ubuntu-drivers >/dev/null 2>&1; then
  echo "Running: ubuntu-drivers devices"
  ubuntu-drivers devices || true
  echo
  echo "Running: ubuntu-drivers autoinstall"
  ubuntu-drivers autoinstall || true
else
  echo "ubuntu-drivers not available. Installing package ubuntu-drivers-common and trying again..."
  apt-get install -y ubuntu-drivers-common || true
  ubuntu-drivers autoinstall || true
fi

# As a fallback, attempt apt install of generic driver meta-package
echo "Also attempting to install nvidia-driver via apt (best-effort)..."
apt-get install -y nvidia-driver nvidia-driver-535 nvidia-utils || true

# 11) Final rebuild and instructions
echo
echo "12) Final update-initramfs and update-grub"
update-initramfs -u || true
update-grub || true

echo
echo "=== Done: purge & reinstall attempted ==="
echo "Reboot now to complete driver installation."
echo "After reboot, check:"
echo "  lsmod | grep nvidia"
echo "  nvidia-smi"
echo "  lspci -k | grep -A3 -i nvidia"
echo
if [ "$DISABLE_AFTER" = true ]; then
  echo "DISABLE_AFTER requested — running disable steps now (best-effort)."
  # Minimal disable sequence (safe) — unbind + blacklist + rebuild
  echo " -> Switching to intel profile (prime-select intel)"
  prime-select intel || true
  echo " -> Creating blacklist file"
  cat > /etc/modprobe.d/blacklist-nvidia.conf <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
  echo " -> Creating udev unbind rule"
  cat > /etc/udev/rules.d/99-nvidia-disable.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", RUN+="/bin/sh -c 'echo $kernel > /sys/bus/pci/devices/$devpath/driver/unbind' || true"
EOF
  udevadm control --reload || true
  update-initramfs -u || true
  echo "Disable-step done. Reboot recommended."
fi

echo "Backup of removed items (package lists/dkms/lsmod/lspci saved) at: $BACKUP"
echo
read -p "Press Enter to reboot now, or Ctrl+C to reboot later..." || true
reboot

