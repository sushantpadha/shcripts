# NVIDIA MY GOAT

**TL;DR**
- `runtime_status` -> is GPU electrically powered?
- `power/control` -> is runtime PM allowed?
- `lsmod` -> are NVIDIA kernel modules loaded?
- `glxinfo | grep renderer` -> which GPU renders desktop?
- these are DIFFERENT things

0. [K.I.S.S.](https://en.wikipedia.org/wiki/KISS_principle)

1. Check GPU runtime power state:
	```bash
	cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
	cat /sys/bus/pci/devices/0000:01:00.0/power/control
	```

	Find PCI address:
	```bash
	lspci -D | grep -Ei 'VGA|3D|NVIDIA'
	```

	Interpretation:
	```text
	runtime_status:
	    active      -> GPU electrically powered
	    suspended   -> GPU suspended

	power/control:
	    auto        -> runtime PM allowed
	    on          -> never runtime suspend
	```

	Healthy idle:
	```text
	runtime_status = suspended
	power/control  = auto
	renderer       = AMD/intel
	total power    ~5-12W
	```

2. `prime-select amd/intel`
- integrated graphics only
- prevents desktop from defaulting to NVIDIA

	```bash
	sudo prime-select amd
	```

3. `prime-select on-demand`
- desktop on iGPU
- CUDA usable manually
- usually best default setup

	```bash
	sudo prime-select on-demand
	```

4. Mask NVIDIA services if disabling GPU:
	```bash
	sudo systemctl mask nvidia-persistenced.service
	sudo systemctl mask nvidia-powerd.service
	```

5. Rebuild initramfs after changing blacklist/module config:
	```bash
	sudo update-initramfs -u
	```

6. Blacklist NVIDIA modules:
- `/etc/modprobe.d/blacklist-nvidia.conf`
	```text
	blacklist nvidia
	blacklist nvidia_drm
	blacklist nvidia_modeset
	blacklist nvidia_uvm
	```

7. Verify NVIDIA state:
	```bash
	lspci -k | grep -A3 -i nvidia
	lsmod | grep nvidia
	glxinfo | grep renderer
	nvidia-smi
	cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
	cat /sys/bus/pci/devices/0000:01:00.0/power/control
	```

	Interpretation:
	```text
	lspci:
	    driver in use: nvidia  -> driver bound
	    driver in use: none    -> unbound

	lsmod:
	    output exists          -> modules loaded

	runtime_status:
	    active                 -> GPU powered
	    suspended              -> GPU suspended

	power/control:
	    auto                   -> runtime PM enabled
	    on                     -> runtime PM disabled
	```

8. Check graphics users if GPU refuses to suspend:
	```bash
	sudo fuser -v /dev/dri/*
	```

	Common offenders:
	```text
	chrome
	firefox
	electron
	discord
	gnome-shell
	```

9. CPU package power matters more than raw CPU usage:
	```bash
	sudo turbostat --Summary
	```

	Important field:
	```text
	PkgWatt
	```

10. Old udev rules can silently keep breaking NVIDIA:
	```bash
	find /etc/udev/rules.d -iname '*nvidia*'
	```

11. Secure Boot can silently break NVIDIA:
	```bash
	mokutil --sb-state
	```

	Typical symptom:
	```text
	nvidia-smi fails
	modprobe nvidia fails
	driver appears installed
	```

12. Persistent config locations:
	```text
	/etc/modprobe.d/
/etc/udev/rules.d/
/etc/default/grub
/etc/modules-load.d/
	```

	Useful inspection:
	```bash
	find /etc/modprobe.d /lib/modprobe.d -iname '*nvidia*'
	find /etc/udev/rules.d -iname '*nvidia*'
	grep -i nvidia /etc/default/grub
	```

13. Recovery order:
	```text
	1. verify state
	2. remove blacklist + udev rules
	3. rebuild initramfs
	4. reboot
	5. reset script
	6. nuke&reinstall only if genuinely cooked
	```