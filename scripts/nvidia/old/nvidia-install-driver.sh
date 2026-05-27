#!/bin/bash

# i am going to use nvidia site se drivers: https://www.nvidia.com/en-in/drivers/
# for that i asked gpt: https://chatgpt.com/c/68e69e4c-bcf4-8320-9798-9b4c4ff65c96
#
# delete existing nvidia
# sudo apt purge 'nvidia-*' && sudo apt autoremove
#
# dependencies
# sudo apt install build-essential dkms linux-headers-$(uname -r)
#
# blacklist open source drivers
# sudo nano /etc/modprobe.d/blacklist-nouveau.conf
# 
# write:
# blacklist nouveau
# options nouveau modeset=0

# sudo update-initramfs -u

# reboot
#
#
# some shit to do after you reboot and open tty mode (ctrl alt f3)
# sudo systemctl stop gdm  # sto pservice
# cd, chmod the .run file and sudo run it
# sudo reboot
# nvidia-smi # test
# dkms status # test it
#
# enable hybrid mode : install nvidia-prime
# sudo prime-select amd
