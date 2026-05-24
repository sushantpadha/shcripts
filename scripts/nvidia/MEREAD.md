# NVIDIA MY GOAT

Edit `06:44 11/10/2025` -- enable and disable MINIMAL scripts work(mostly) ; use nuke&reinstall if shit goes south ; use common sense (and stuff listed here) to verify if they worked ; remember pt 0 

**TL;DR**: to verify powered down you read GPU power/state from `/sys/bus/pci/devices/<gpu_pci_add>/...` and to verify kernel module is *not loaded*, you check `lscpi -k | grep nvidia`.

0. [K.I.S.S.](https://en.wikipedia.org/wiki/KISS_principle)

1. You can read the GPU power/state/enablestatus by:  
	```bash
	cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
	cat /sys/bus/pci/devices/0000:01:00.0/power_state
	cat /sys/bus/pci/devices/0000:01:00.0/enable
    ```  
	- Replace `0000:01:00.0` with your GPU’s PCI address (check with `lspci | grep NVIDIA`)  
	- This tells you if the GPU is **D0 (active)** or **D3cold/D3hot (suspended/powered down)**

2. `prime-select intel` → switches the system to use integrated graphics only (Intel/AMD).  
- Required to prevent Xorg / Wayland from automatically using the NVIDIA GPU.

3. `systemctl` → use to **mask/disable NVIDIA services** such as `nvidia-persistenced.service` and `nvidia-powerd.service`.  
- Don’t create extra services unnecessarily; just stick to these.

4. **Disable automatic Xorg / Wayland probing of NVIDIA**  
- GNOME Shell (Mutter) and Xorg can probe all GPUs at login.  
- If NVIDIA is detected, it can wake the GPU even if blacklisted.  
- Using a **udev PCI unbind rule** prevents the driver from binding automatically and keeps the GPU in D3cold.

5. **Do NOT add extra services** beyond the essential NVIDIA ones.  
- Extra services are hard to manage and remove later.

6. **Rebuild initramfs** after blacklisting NVIDIA kernel modules to ensure they are not loaded at boot:  
	```bash
	sudo update-initramfs -u
	```

7. **Blacklisting NVIDIA kernel modules** prevents them from loading automatically:  
- `/etc/modprobe.d/blacklist-nvidia.conf`:
	```
	blacklist nvidia
	blacklist nvidia_drm
	blacklist nvidia_modeset
	blacklist nvidia_uvm
	```

8. **Optional GRUB edit**: add `modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm` to `GRUB_CMDLINE_LINUX_DEFAULT` to prevent kernel from loading NVIDIA modules at boot.  
- Then `sudo update-grub`.

9. **Verify NVIDIA status**:  
	```bash
	lspci -k | grep -A3 -i nvidia    # check kernel driver bound
	lsmod | grep nvidia               # check loaded modules
	nvidia-smi                        # check if GPU is active
	cat /sys/bus/pci/devices/0000:01:00.0/power_state
	cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
	```
- `lspci` shows which driver is in use (`nvidia` → active, `(none)` → unbound)  
- `lsmod` shows if NVIDIA modules are loaded  
- `nvidia-smi` shows GPU activity  
- `/sys/bus/pci/devices/.../power_state` shows current power state

