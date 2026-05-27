#!/bin/bash
# ==========================================================
# disable-nvidia-24.04.sh
# Full NVIDIA GPU disable script for Ubuntu 24.04 dual-GPU laptops
# (tested on HP Omen 16 / hybrid graphics systems)
#
# Based on: https://chatgpt.com/c/68e93ba8-5f54-8321-91d1-c3673dbfd79b
#
# This script:
#   • Switches to integrated graphics (Intel/AMD)
#   • Masks NVIDIA services and udev triggers
#   • Blacklists NVIDIA kernel modules
#   • Adds kernel-level blacklisting (GRUB)
#   • Optionally unbinds NVIDIA PCI device to cut power
#   • Rebuilds initramfs and reloads udev
#
# To revert:
#   sudo prime-select nvidia
#   sudo rm /etc/modprobe.d/blacklist-nvidia.conf
#   sudo rm /etc/udev/rules.d/99-nvidia-disable.rules
#   sudo sed -i 's/modprobe.blacklist=[^"]*//' /etc/default/grub
#   sudo update-initramfs -u && sudo update-grub
#   sudo systemctl unmask nvidia-* && sudo reboot
# ==========================================================

echo "⚠️  This script makes persistent system-level changes."
read -p "Press Enter to continue or Ctrl+C to abort..."

# ==========================================================
# 1. Switch to integrated graphics
# ==========================================================
sudo prime-select intel
echo ">>> Active GPU profile: $(sudo prime-select query)"
read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 2. Mask NVIDIA-related services
# ==========================================================
echo -e "\n>>> Masking NVIDIA systemd services..."
disable_list=(
  "nvidia-hibernate.service"
  "nvidia-powerd.service"
  "nvidia-persistenced.service"
  "nvidia-resume.service"
  "nvidia-suspend.service"
  "nvidia-suspend-then-hibernate.service"
)
for serv in "${disable_list[@]}"; do
  sudo systemctl disable --now "$serv" 2>/dev/null
  sudo systemctl mask "$serv" 2>/dev/null
done

read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 3. Blacklist NVIDIA kernel modules
# ==========================================================
echo -e "\n>>> Creating /etc/modprobe.d/blacklist-nvidia.conf ..."
sudo tee /etc/modprobe.d/blacklist-nvidia.conf > /dev/null <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
options nvidia NVreg_DynamicPowerManagement=0x02
EOF

# ==========================================================
# 4. Disable NVIDIA udev autoload rules
# ==========================================================
echo -e "\n>>> Overriding NVIDIA udev rules..."
sudo mkdir -p /etc/udev/rules.d
if [ -f /lib/udev/rules.d/71-nvidia.rules ]; then
  sudo cp /lib/udev/rules.d/71-nvidia.rules /etc/udev/rules.d/71-nvidia.rules
  sudo sed -i 's/.*RUN+/#&/' /etc/udev/rules.d/71-nvidia.rules
fi

# ==========================================================
# 5. Add PCI auto-unbind rule (prevents power drain)
# ==========================================================
echo -e "\n>>> Creating /etc/udev/rules.d/99-nvidia-disable.rules ..."
sudo tee /etc/udev/rules.d/99-nvidia-disable.rules > /dev/null <<'EOF'
# Automatically unbind NVIDIA GPU from its driver on boot
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", RUN+="/bin/sh -c 'echo $kernel > /sys/bus/pci/devices/$devpath/driver/unbind'"
EOF
sudo udevadm control --reload

read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 6. Add kernel-level blacklist to GRUB
# ==========================================================
echo -e "\n>>> Adding modprobe blacklist to GRUB boot parameters..."
sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/{
  /modprobe.blacklist=/! s/\"\(.*\)\"/\"\1 modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm\"/
}' /etc/default/grub
sudo update-grub

read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 7. Rebuild initramfs
# ==========================================================
echo -e "\n>>> Updating initramfs..."
sudo update-initramfs -u
KERNEL_VER=$(uname -r)
echo -e "\n>>> Checking initramfs for NVIDIA modules..."
lsinitramfs /boot/initrd.img-"$KERNEL_VER" | grep nvidia || echo "(no NVIDIA modules found — good)"

read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 8. Secure Boot check
# ==========================================================
echo -e "\n>>> Checking Secure Boot status..."
if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
  echo "⚠️  Secure Boot is ENABLED."
  echo "    This can cause signed NVIDIA modules to load before blacklisting."
  echo "    If GPU stays active, consider disabling Secure Boot in BIOS."
else
  echo "✅ Secure Boot is disabled or not in use."
fi

read -p "Press Enter or Ctrl+C to continue..."

# ==========================================================
# 9. Reboot instructions
# ==========================================================
echo -e "\n✅ Done! Please reboot to apply changes."
echo "After reboot, verify with:"
echo "  lsmod | grep nvidia"
echo "  lspci -k | grep -A 3 -i nvidia"
echo "  cat /sys/bus/pci/devices/*/power/runtime_status | grep -i suspended"
echo "Expected: no NVIDIA modules loaded, runtime_status = suspended"
echo
echo "To undo: see comments at top of this script."
# ==========================================================

