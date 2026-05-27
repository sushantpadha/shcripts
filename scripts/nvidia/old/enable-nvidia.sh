#!/bin/bash
# ==========================================================
# enable-nvidia-24.04.sh
# Undo the disable script and restore NVIDIA functionality
# ==========================================================
sudo prime-select nvidia
sudo rm -f /etc/modprobe.d/blacklist-nvidia.conf
sudo rm -f /etc/udev/rules.d/99-nvidia-disable.rules
sudo rm -f /etc/udev/rules.d/71-nvidia.rules
sudo sed -i 's/modprobe.blacklist=[^"]*//' /etc/default/grub
sudo update-initramfs -u && sudo update-grub
sudo systemctl unmask nvidia-*
sudo reboot
# ==========================================================

