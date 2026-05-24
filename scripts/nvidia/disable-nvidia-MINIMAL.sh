#!/bin/bash
# ==========================================================
# disable-nvidia-minimal.sh
# Minimal NVIDIA GPU disable script for Ubuntu 24.04 (hybrid laptops)
# Tested on HP Omen 16 (Intel + NVIDIA)
#
# What it does:
#   • Switches to integrated graphics
#   • Masks NVIDIA systemd services
#   • Blacklists NVIDIA kernel modules
#   • Adds udev rule to unbind PCI device (for power savings)
#   • Rebuilds initramfs
#
# To RE-ENABLE NVIDIA:
#   sudo prime-select nvidia
#   sudo rm -f /etc/modprobe.d/blacklist-nvidia.conf
#   sudo rm -f /etc/udev/rules.d/99-nvidia-disable.rules
#   sudo systemctl unmask nvidia-*
#   sudo update-initramfs -u
#   sudo reboot
#
# Optional GRUB blacklisting can be added later if modules still autoload.
# ==========================================================

set -e

echo "⚠️  This script disables NVIDIA GPU temporarily (until reverted)."
read -p "Press Enter to continue or Ctrl+C to abort..."

# ==========================================================
# 1. Switch to integrated graphics
# ==========================================================
echo -e "\n>>> Switching to integrated GPU..."
sudo prime-select intel || echo "(prime-select intel failed)"
echo "Current profile: $(sudo prime-select query)"

# ==========================================================
# 2. Mask NVIDIA-related services
# ==========================================================
echo -e "\n>>> Masking NVIDIA systemd services..."
services=(
  nvidia-persistenced.service
  nvidia-powerd.service
  nvidia-hibernate.service
  nvidia-resume.service
  nvidia-suspend.service
)
for s in "${services[@]}"; do
  sudo systemctl disable --now "$s" 2>/dev/null || true
  sudo systemctl mask "$s" 2>/dev/null || true
done

# ==========================================================
# 3. Blacklist NVIDIA kernel modules
# ==========================================================
echo -e "\n>>> Blacklisting NVIDIA kernel modules..."
sudo tee /etc/modprobe.d/blacklist-nvidia.conf >/dev/null <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

# ==========================================================
# 4. Add PCI unbind rule (power off discrete GPU)
# ==========================================================
echo -e "\n>>> Creating udev rule to unbind NVIDIA GPU..."
sudo tee /etc/udev/rules.d/99-nvidia-disable.rules >/dev/null <<'EOF'
# Automatically unbind NVIDIA GPU from its driver on boot (reduces power)
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", RUN+="/bin/sh -c 'echo $kernel > /sys/bus/pci/devices/$devpath/driver/unbind'"
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card*", ATTR{vendor}=="0x10de", RUN+="/bin/rm -f /dev/$name"
EOF
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de

# ==========================================================
# 5. Rebuild initramfs
# ==========================================================
echo -e "\n>>> Rebuilding initramfs..."
sudo update-initramfs -u

# ==========================================================
# 6. Final info
# ==========================================================
echo -e "\n✅ Done. Reboot to apply changes."
echo "After reboot, verify with:"
echo "  lsmod | grep nvidia           # should show nothing"
echo "  lspci -k | grep -A3 -i nvidia # should show 'Kernel driver in use: vfio-pci' or none"
echo "  cat /sys/bus/pci/devices/*/power/runtime_status | grep suspended"
echo
echo "To re-enable: see 'To RE-ENABLE NVIDIA' comment at top of script."

