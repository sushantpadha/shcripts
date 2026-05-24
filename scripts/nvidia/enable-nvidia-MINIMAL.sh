#!/bin/bash
# ==========================================================
# nvidia-on-demand.sh
# Configure NVIDIA GPU on Ubuntu 24.04 for on-demand use:
# - GPU remains powered but not used by Xorg/Wayland
# - Manual activation possible for PyTorch/CUDA
# ==========================================================

echo "⚠️  This will configure your NVIDIA GPU for on-demand use."
read -p "Press Enter to continue or Ctrl+C to abort..."

# -----------------------------
# 1. Switch to on-demand mode
# -----------------------------
echo -e "\n>>> Switching to NVIDIA On-Demand profile..."
sudo prime-select on-demand
sudo update-initramfs -u
echo "Current GPU profile: $(sudo prime-select query)"
read -p "Press Enter"
# -----------------------------
# 2. Disable NVIDIA services
# -----------------------------
echo -e "\n>>> Masking and stopping NVIDIA services..."
services=(
    nvidia-persistenced.service
    nvidia-powerd.service
)
for s in "${services[@]}"; do
    sudo systemctl stop "$s" 2>/dev/null || true
    sudo systemctl mask "$s" 2>/dev/null || true
done
read -p "Press Enter"
# -----------------------------
# 3. Blacklist NVIDIA modules
# -----------------------------
echo -e "\n>>> Creating blacklist for NVIDIA kernel modules..."
sudo tee /etc/modprobe.d/blacklist-nvidia.conf > /dev/null <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
read -p "Press Enter"
# -----------------------------
# 4. Prevent Xorg/Wayland from using NVIDIA
# -----------------------------
echo -e "\n>>> Creating Xorg configuration to ignore NVIDIA GPU..."
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/10-nvidia.conf > /dev/null <<'EOF'
Section "Device"
    Identifier "NVIDIA"
    Driver "nvidia"
    BusID "PCI:1:0:0"  # Replace with your GPU's PCI address from lspci
    Option "AllowEmptyInitialConfiguration"
    Option "IgnoreDisplayDevices" "CRT"
    Option "PrimaryGPU" "No"
EndSection
EOF
echo "Please update xorg config to reflect actualy GPU PCI address!"
echo "@ /etc/X11/xorg.conf.d/10-nvidia.conf"

read -p "Press Enter"

# -----------------------------
# 5. Rebuild initramfs
# -----------------------------
echo -e "\n>>> Updating initramfs..."
sudo update-initramfs -u

# -----------------------------
# 6. Manual access instructions
# -----------------------------
echo -e "\n✅ NVIDIA GPU is now on-demand (powered but idle)."
echo "To use GPU manually for PyTorch/CUDA:"
echo -e "\t sudo modprobe nvidia"
echo -e "\t export __NV_PRIME_RENDER_OFFLOAD=1"
echo -e "\t export __GLX_VENDOR_LIBRARY_NAME=nvidia"
echo -e "\t python your_script.py"
echo -e "\nCheck GPU state with:"
echo -e "\t lspci -k | grep -A3 -i nvidia"
echo -e "\t lsmod | grep nvidia"
echo -e "\t cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status"

echo -e "\n💡 Reboot recommended to fully apply changes."

