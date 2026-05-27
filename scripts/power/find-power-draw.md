# Linux Laptop Power / Thermal Debugging Cheat Sheet

System:

* HP Omen 16
* Ryzen 7 7840HS
* RTX 4050 Mobile
* Ubuntu 24

Healthy idle expectations:

```text id="9x6ldz"
Power draw      : ~5-12W
CPU clocks      : mostly low/spiky, not pinned high
CPU temp        : ~40-60C
NVIDIA state    : suspended
Desktop GPU     : integrated AMD/iGPU
Fans            : low or off
```

Quick checks:

```bash id="lqpl2h"
sudo powertop
```

```bash id="l72z0u"
watch sensors
```

```bash id="i9gq0z"
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

```bash id="7mpm8u"
glxinfo | grep renderer
```

---

# Debug Flow

```text id="j1q6c0"
High Power Usage
│
├── CPU busy/high clocks?
│
├── NVIDIA awake?
│
├── Browser/Electron apps?
│
├── PCIe power saving broken?
│
└── Fans reacting correctly?
```

---

## Total Power Draw

Check estimated system power usage.

```bash id="rdrmji"
sudo powertop
```

```text id="j9wuyx"
5-12W   good idle
15-25W  suspicious
30W+    something wrong
```

---

## CPU Usage

Check top CPU users.

```bash id="r1s07l"
htop
```

Useful:

```text id="v6ixq2"
P = sort by CPU
M = sort by memory
```

CLI version:

```bash id="s6m8kx"
ps -eo pid,cmd,%cpu --sort=-%cpu | head
```

---

## CPU Temperatures

Check thermals/fans.

```bash id="r7v9ij"
watch sensors
```

---

## CPU Clocks

Check if CPU is idling properly.

```bash id="g2v8gc"
watch "grep 'cpu MHz' /proc/cpuinfo"
```

High sustained idle clocks = likely power issue.

---

## CPU Package Power

Check real CPU power draw.

```bash id="lzyrme"
sudo turbostat --Summary
```

Important field:

```text id="1zsv7q"
PkgWatt
```

---

## Is NVIDIA Awake

Check if runtime power state is suspended/active.

```bash id="gkvlhd"
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

```text id="y7d59m"
suspended = sleeping
active    = powered on
```

---

## Allow NVIDIA To Sleep

Enable runtime power management.

```bash id="jlwmjq"
echo auto | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control
```

Recheck:

```bash id="j7jew6"
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

---

## Which Driver Owns NVIDIA

Check whether `nvidia` or `nouveau` is loaded.

```bash id="2e0mkl"
lspci -k -s 01:00.0
```

```text id="xfr5bh"
nvidia   = proprietary driver
nouveau  = open-source driver
```

Loaded GPU modules:

```bash id="zqjlwm"
lsmod | grep -E "nvidia|nouveau|amdgpu"
```

---

## Which GPU Renders Desktop

Desktop should ideally use iGPU.

```bash id="jvng4q"
glxinfo | grep renderer
```

Good:

```text id="okjlwm"
AMD Radeon Graphics
```

Bad for battery:

```text id="s6jlwm"
NVIDIA RTX 4050
```

---

## Which Processes Use GPU

Check graphics device users.

```bash id="jlwm4o"
sudo fuser -v /dev/dri/*
```

Common offenders:

```text id="jlwm2v"
chrome
firefox
electron
discord
gnome-shell
```

---

## Remove Nouveau Temporarily

Useful test if NVIDIA won't suspend.

```bash id="jlwm2o"
sudo modprobe -r nouveau
```

Then:

```bash id="jlwm2p"
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

---

## Disable CPU Turbo

Large thermal reduction.

```bash id="jlwm2q"
echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

Restore:

```bash id="jlwm2r"
echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo
```

---

## Use Real Power Saving Mode

GNOME GUI “Power Saver” mostly:

* lowers CPU aggressiveness,
* prefers low frequencies,
* reduces boost behavior.

Enable:

```bash id="jlwm2s"
powerprofilesctl set power-saver
```

Check:

```bash id="jlwm2t"
powerprofilesctl get
```

---

## Stronger Laptop Power Saving

TLP applies more aggressive policies.

```bash id="jlwm2u"
sudo apt install tlp
sudo systemctl enable tlp
sudo systemctl start tlp
```

Check:

```bash id="jlwm2v"
sudo tlp-stat -s
```

---

## Check X11 vs Wayland

Wayland often handles hybrid GPUs better.

```bash id="jlwm2w"
echo $XDG_SESSION_TYPE
```

---

## Check PCIe ASPM

Bad ASPM hurts idle power badly.

```bash id="jlwm2x"
sudo lspci -vv -s 01:00.0
```

Search for:

```text id="jlwm2y"
ASPM Disabled
```

---

# Fast Minimal Routine

```bash id="jlwm30"
sudo powertop
```

```bash id="jlwm31"
htop
```

```bash id="jlwm32"
watch sensors
```

```bash id="jlwm33"
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
```

```bash id="jlwm34"
glxinfo | grep renderer
```

```bash id="jlwm35"
sudo fuser -v /dev/dri/*
```

```bash id="jlwm36"
sudo turbostat --Summary
```
