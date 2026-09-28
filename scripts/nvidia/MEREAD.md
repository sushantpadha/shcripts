# NVIDIA MY GOAT

**TL;DR**
- `runtime_status` -> is GPU electrically powered?
- `power/control` -> is runtime PM allowed?
- `lsmod` -> are NVIDIA kernel modules loaded?
- `glxinfo | grep renderer` -> which GPU renders desktop?
- these are DIFFERENT things

0. [K.I.S.S.](https://en.wikipedia.org/wiki/KISS_principle)

Scripts in this folder:
- `psm.sh` -> menu: status (read-only, never wakes the GPU), off, on-demand. Backs up everything it touches to `/var/backups/psm/<time>/` with a `RESTORE.sh`.
- `doctor.sh` -> read-only dump of driver, DKMS, Secure Boot, power state.

On this laptop the GPU is `0000:01:00.0`. The addresses below are examples; `psm.sh` finds yours itself.

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

2. `prime-select intel`
- integrated graphics only (the profile is called `intel` even on an AMD iGPU; there is no `amd`)
- prevents desktop from defaulting to NVIDIA
- blacklists the nvidia modules and rebuilds the initramfs
- this is what `psm.sh off` runs

	```bash
	sudo prime-select intel
	```

3. `prime-select on-demand`
- desktop on iGPU
- CUDA usable manually
- usually best default setup
- enables runtime power management (RTD3) so the idle GPU can suspend
- this is what `psm.sh on-demand` runs

	```bash
	sudo prime-select on-demand
	```

4. Stop NVIDIA services if disabling GPU:
	```bash
	sudo systemctl mask nvidia-persistenced.service
	sudo systemctl mask nvidia-powerd.service
	```
	`psm.sh off` only disables `nvidia-powerd` (persistenced is static and is only started when the driver loads).

5. Rebuild initramfs after changing blacklist/module config:
	```bash
	sudo update-initramfs -u
	```

6. Blacklist NVIDIA modules:
- `prime-select intel` writes `/lib/modprobe.d/blacklist-nvidia.conf`
- an old hand-made `/etc/modprobe.d/blacklist-nvidia.conf` is a leftover: `psm.sh` backs it up and removes it
	```text
	blacklist nvidia
	blacklist nvidia_drm
	blacklist nvidia_modeset
	blacklist nvidia_uvm
	```
- a blacklist does NOT stop `nvidia` loading as a dependency of `nvidia_uvm`, so `psm.sh off` also writes `/etc/modprobe.d/psm-nvidia-off.conf`:
	```text
	install nvidia /bin/false
	```
- `psm.sh off` also writes a udev rule (`/etc/udev/rules.d/80-psm-nvidia-off.rules`) setting `power/control=auto`, so the driverless GPU can power down

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

	A copy of `71-nvidia.rules` in `/etc` overrides the stock one in `/usr/lib/udev/rules.d/`. An old one with the `nvidia-drm` / `nvidia-uvm` autoload lines commented out breaks on-demand mode. `psm.sh` removes it.

	Do NOT remove `/etc/u-d-c-nvidia-runtimepm-override`: it is what makes RTD3 available on this machine.

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
	/lib/modprobe.d/          (prime-select writes here)
	/etc/udev/rules.d/
	/etc/default/grub         (psm.sh warns about nvidia args here, never edits it)
	/etc/modules-load.d/
	/var/backups/psm/         (psm.sh backups + RESTORE.sh)
	```

	Useful inspection:
	```bash
	find /etc/modprobe.d /lib/modprobe.d -iname '*nvidia*'
	find /etc/udev/rules.d -iname '*nvidia*'
	grep -i nvidia /etc/default/grub /etc/default/grub.d/*.cfg
	```

13. Recovery order:
	```text
	1. verify state                 (psm.sh status)
	2. undo the last psm.sh run     (sudo bash /var/backups/psm/<time>/RESTORE.sh)
	   or remove blacklist + udev rules by hand
	3. rebuild initramfs            (sudo update-initramfs -u)
	4. reboot
	5. sudo prime-select on-demand  (safe default), reboot again
	6. nuke&reinstall only if genuinely cooked
	```
