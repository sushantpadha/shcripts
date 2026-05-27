#!/usr/bin/env bash
# ==========================================================
# nvidia-psm
#
# NVIDIA Power State Manager for Ubuntu 24 hybrid laptops
#
# Tested target:
#   - HP Omen 16
#   - Ryzen 7 7840HS
#   - RTX 4050 Mobile
#   - Ubuntu 24
#
# ==========================================================
#
# MODES
#
# off
#   - aggressively disable NVIDIA
#   - desktop uses iGPU
#   - runtime PM enabled
#   - blacklists NVIDIA modules
#
# lowpower
#   - desktop uses iGPU
#   - CUDA usable manually
#   - NVIDIA power capped
#
# full
#   - full NVIDIA performance
#   - desktop may render on NVIDIA
#
# reset
#   - restore sane Ubuntu defaults
#
# ==========================================================
#
# DIAGNOSTICS
#
# status
#   - compact overview
#
# diagnose
#   - verbose debugging dump
#
# doctor
#   - detect broken/stale configuration
#
# ==========================================================
#
# DRIVER
#
# update
#   - install Ubuntu recommended NVIDIA driver
#
# ==========================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SERVICES=(
    nvidia-persistenced.service
    nvidia-powerd.service
    nvidia-hibernate.service
    nvidia-resume.service
    nvidia-suspend.service
)

REBOOT_REQUIRED=false

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
RESET="\033[0m"

# ==========================================================
# error trap
# ==========================================================

trap '{
    echo
    bad "Script failed near line $LINENO"
    echo
    warn "Please copy the ENTIRE terminal output if asking for help."
    echo
    warn "Useful recovery commands:"
    echo "    $SCRIPT_NAME doctor"
    echo "    $SCRIPT_NAME reset"
    echo
}' ERR

# ==========================================================
# logging
# ==========================================================

info() {
    echo -e "${BLUE}>>>${RESET} $*"
}

good() {
    echo -e "${GREEN}>>>${RESET} $*"
}

warn() {
    echo -e "${YELLOW}>>>${RESET} $*"
}

bad() {
    echo -e "${RED}>>>${RESET} $*"
}

header() {
    echo
    echo "=========================================================="
    echo " NVIDIA Power State Manager"
    echo "=========================================================="
    echo
}

pause() {
    read -rp "Press Enter to continue..."
}

confirm_action() {
    echo
    warn "$1"
    echo

    read -rp "Continue? [y/N]: " ans

    [[ "$ans" =~ ^[Yy]$ ]]
}

run() {
    local desc="$1"
    shift

    echo
    info "$desc"
    echo "CMD: $*"
    echo

    "$@"
}

# ==========================================================
# helpers
# ==========================================================

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        bad "Missing command: $1"
        exit 1
    }
}

gpu_present() {
    lspci | grep -qi nvidia
}

gpu_sysfs() {
    echo "/sys/bus/pci/devices/$GPU_BDF"
}

gpu_power_control_path() {
    echo "$(gpu_sysfs)/power/control"
}

runtime_status() {
    cat "$(gpu_sysfs)/power/runtime_status" 2>/dev/null || echo "unknown"
}

power_control() {
    cat "$(gpu_power_control_path)" 2>/dev/null || echo "unknown"
}

renderer() {
    glxinfo 2>/dev/null | grep -i "OpenGL renderer" || true
}

# ==========================================================
# PCI detection
# ==========================================================

detect_gpu_bdf() {
    local detected

    detected=$(
        lspci -D |
        grep -Ei 'VGA|3D' |
        grep -i nvidia |
        awk '{print $1}' |
        head -n1
    )

    if [[ -z "$detected" ]]; then
        bad "Could not detect NVIDIA GPU PCI address"
        exit 1
    fi

    GPU_BDF="$detected"

    echo
    info "Detected NVIDIA GPU PCI address"
    echo "    $GPU_BDF"
    echo

    echo "Verify manually with:"
    echo "    lspci -D | grep -Ei 'VGA|3D|NVIDIA'"
    echo

    read -rp "Does this look correct? [y/N]: " ans

    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        warn "Aborting."
        exit 1
    fi
}

detect_audio_bdf() {
    AUDIO_BDF=$(
        lspci -D |
        grep -i nvidia |
        grep -i audio |
        awk '{print $1}' |
        head -n1
    )

    [[ -n "${AUDIO_BDF:-}" ]] || AUDIO_BDF="none"
}

# ==========================================================
# services
# ==========================================================

mask_services() {
    for s in "${SERVICES[@]}"; do
        sudo systemctl stop "$s" 2>/dev/null || true
        sudo systemctl disable "$s" 2>/dev/null || true
        sudo systemctl mask "$s" 2>/dev/null || true
    done
}

unmask_services() {
    for s in "${SERVICES[@]}"; do
        sudo systemctl unmask "$s" 2>/dev/null || true
    done
}

# ==========================================================
# persistent config cleanup
# ==========================================================

remove_disable_rules() {
    info "Removing stale NVIDIA disable rules"

    sudo rm -f /etc/udev/rules.d/99-nvidia-disable.rules
    sudo rm -f /etc/modprobe.d/blacklist-nvidia.conf

    sudo udevadm control --reload || true
}

# ==========================================================
# verification
# ==========================================================

verify_off_mode() {
    echo
    info "Verification"

    echo
    echo "PRIME profile:"
    prime-select query || true

    echo
    echo "Runtime status:"
    runtime_status

    echo
    echo "Loaded NVIDIA modules:"
    lsmod | grep nvidia || echo "none"

    echo
    echo "Renderer:"
    renderer
}

verify_lowpower_mode() {
    echo
    info "Verification"

    echo
    echo "PRIME profile:"
    prime-select query || true

    echo
    echo "Runtime status:"
    runtime_status

    echo
    echo "Renderer:"
    renderer

    echo
    echo "nvidia-smi:"
    nvidia-smi || true
}

verify_full_mode() {
    echo
    info "Verification"

    echo
    echo "PRIME profile:"
    prime-select query || true

    echo
    echo "Renderer:"
    renderer

    echo
    echo "nvidia-smi:"
    nvidia-smi || true
}

# ==========================================================
# status
# ==========================================================

status() {
    header

    info "GPU runtime state"
    echo "    $(runtime_status)"
    echo

    info "Runtime PM policy"
    echo "    $(power_control)"
    echo

    info "Current PRIME profile"
    prime-select query 2>/dev/null || true
    echo

    info "OpenGL renderer"
    renderer
    echo

    info "Loaded GPU kernel modules"
    lsmod | grep -E "nvidia|nouveau|amdgpu" || echo "none"
    echo

    info "NVIDIA PCI binding"
    lspci -k -s "$GPU_BDF" || true
    echo

    info "NVIDIA audio function"
    echo "    $AUDIO_BDF"
    echo

    info "Thermals"
    sensors 2>/dev/null || true
    echo

    info "Top CPU users"
    ps -eo pid,cmd,%cpu --sort=-%cpu | head
    echo

    info "Processes using graphics stack"
    sudo fuser -v /dev/dri/* 2>/dev/null || true
    echo

    info "CPU package power"
    sudo turbostat --Summary --quiet 2>/dev/null || true
    echo

    if command -v nvidia-smi >/dev/null 2>&1; then
        info "NVIDIA telemetry"

        nvidia-smi \
            --query-gpu=power.draw,temperature.gpu,utilization.gpu,memory.used \
            --format=csv \
            2>/dev/null || echo "NVIDIA driver inactive"

        echo
    fi
}

# ==========================================================
# diagnose
# ==========================================================

diagnose() {
    header

    info "Kernel"
    uname -a
    echo

    info "PCI topology"
    lspci | grep -Ei "vga|3d|display|nvidia|amd"
    echo

    info "Detailed NVIDIA PCI info"
    sudo lspci -vv -s "$GPU_BDF" || true
    echo

    info "Kernel logs"
    dmesg | grep -iE "nvidia|nouveau|amdgpu|acpi|pci" | tail -n 100 || true
    echo

    info "Session type"
    echo "${XDG_SESSION_TYPE:-unknown}"
    echo

    info "Graphics renderer"
    renderer
    echo

    info "Runtime PM"
    echo "runtime_status : $(runtime_status)"
    echo "power/control  : $(power_control)"
    echo

    info "Interrupt activity"
    cat /proc/interrupts | grep -Ei "nvidia|amdgpu|nvme|xhci" || true
    echo

    info "CPU package power"
    sudo turbostat --Summary --quiet 2>/dev/null || true
    echo
}

# ==========================================================
# doctor
# ==========================================================

doctor() {
    header

    info "Checking PRIME profile"
    prime-select query || true
    echo

    info "Checking runtime PM"
    echo "runtime_status: $(runtime_status)"
    echo "power/control : $(power_control)"
    echo

    info "Checking loaded modules"
    lsmod | grep -E "nvidia|nouveau" || echo "none"
    echo

    info "Checking stale udev rules"
    find /etc/udev/rules.d -iname '*nvidia*' || true
    echo

    info "Checking blacklist files"
    find /etc/modprobe.d -iname '*nvidia*' || true
    echo

    info "Checking initramfs contamination"
    lsinitramfs /boot/initrd.img-$(uname -r) | grep nvidia || echo "none"
    echo

    info "Checking Secure Boot"
    mokutil --sb-state 2>/dev/null || true
    echo

    info "Checking DKMS"
    dkms status || true
    echo

    info "Checking renderer"
    renderer
    echo

    info "Checking NVIDIA driver"
    modinfo nvidia 2>/dev/null | head || echo "driver missing"
    echo
}

# ==========================================================
# reset
# ==========================================================

reset_mode() {
    header

    warn "Resetting NVIDIA configuration to sane Ubuntu defaults"

    echo
    echo "This will:"
    echo "  - remove NVIDIA blacklists"
    echo "  - remove NVIDIA unbind rules"
    echo "  - unmask NVIDIA services"
    echo "  - switch PRIME to on-demand"
    echo "  - rebuild initramfs"
    echo

    echo "This is SAFE and intended as recovery."
    echo

    confirm_action \
        "Proceed with reset?" \
        || exit 1

    run "Removing blacklist" \
        sudo rm -f /etc/modprobe.d/blacklist-nvidia.conf

    run "Removing udev rules" \
        sudo rm -f /etc/udev/rules.d/99-nvidia-disable.rules

    run "Reloading udev" \
        sudo udevadm control --reload

    run "Unmasking NVIDIA services" \
        unmask_services

    run "Switching PRIME profile" \
        sudo prime-select on-demand

    run "Updating initramfs" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    good "Reset complete"

    echo
    echo "Recommended next steps:"
    echo "    $SCRIPT_NAME status"
    echo "    reboot"
}

# ==========================================================
# OFF mode
# ==========================================================

off_mode() {
    header

    warn "Switching to OFF mode"

    echo
    echo "This mode is PERSISTENT across reboot."
    echo
    echo "Effects:"
    echo "  - desktop uses iGPU"
    echo "  - NVIDIA modules blacklisted"
    echo "  - NVIDIA services masked"
    echo "  - runtime PM enabled"
    echo
    echo "To revert:"
    echo "    $SCRIPT_NAME reset"
    echo

    confirm_action \
        "Apply OFF mode?" \
        || exit 1

    run "Removing stale rules" \
        remove_disable_rules

    run "Switching PRIME profile" \
        bash -c 'sudo prime-select amd || sudo prime-select intel'

    run "Masking NVIDIA services" \
        mask_services

    run "Creating blacklist file" \
        bash -c "sudo tee /etc/modprobe.d/blacklist-nvidia.conf >/dev/null <<EOF
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF"

    run "Creating unbind rule" \
        bash -c "sudo tee /etc/udev/rules.d/99-nvidia-disable.rules >/dev/null <<EOF
ACTION==\"add\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"0x10de\", RUN+=\"/bin/sh -c 'echo \\\$kernel > /sys/bus/pci/devices/\\\$devpath/driver/unbind'\"
EOF"

    if [[ -e "$(gpu_power_control_path)" ]]; then
        run "Enabling runtime PM" \
            bash -c "echo auto | sudo tee '$(gpu_power_control_path)'"
    else
        warn "GPU power control path missing"
    fi

    if [[ -e "$(gpu_sysfs)/driver/unbind" ]]; then
        run "Attempting immediate GPU unbind" \
            bash -c "echo '$GPU_BDF' | sudo tee '$(gpu_sysfs)/driver/unbind'"
    else
        warn "GPU unbind path missing"
    fi

    run "Updating initramfs" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    good "OFF mode configured"

    verify_off_mode
}

# ==========================================================
# LOWPOWER mode
# ==========================================================

lowpower_mode() {
    header

    warn "Switching to LOWPOWER mode"

    echo
    echo "This mode is PERSISTENT across reboot."
    echo
    echo "Effects:"
    echo "  - desktop uses iGPU"
    echo "  - CUDA usable"
    echo "  - NVIDIA power capped"
    echo
    echo "To revert:"
    echo "    $SCRIPT_NAME reset"
    echo

    confirm_action \
        "Apply LOWPOWER mode?" \
        || exit 1

    run "Removing stale rules" \
        remove_disable_rules

    run "Switching PRIME profile" \
        sudo prime-select on-demand

    run "Unmasking NVIDIA services" \
        unmask_services

    run "Updating initramfs" \
        sudo update-initramfs -u

    info "Loading NVIDIA module"

    if ! sudo modprobe nvidia; then
        warn "Failed to load NVIDIA module"
        warn "Driver may be missing or Secure Boot may block loading"
    fi

    sleep 2

    warn "Power limiting requires proprietary NVIDIA driver"

    info "Applying 45W power cap"

    if ! sudo nvidia-smi -pl 45; then
        warn "Failed to apply power limit"
        warn "nvidia-smi may be unavailable"
    fi

    REBOOT_REQUIRED=true

    good "LOWPOWER mode configured"

    verify_lowpower_mode
}

# ==========================================================
# FULL mode
# ==========================================================

full_mode() {
    header

    warn "Switching to FULL mode"

    echo
    echo "This mode is PERSISTENT across reboot."
    echo
    echo "Effects:"
    echo "  - full NVIDIA performance"
    echo "  - desktop may render on NVIDIA"
    echo
    echo "To revert:"
    echo "    $SCRIPT_NAME reset"
    echo

    confirm_action \
        "Apply FULL mode?" \
        || exit 1

    run "Removing stale rules" \
        remove_disable_rules

    run "Switching PRIME profile" \
        sudo prime-select nvidia

    run "Unmasking NVIDIA services" \
        unmask_services

    run "Updating initramfs" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    good "FULL mode configured"

    verify_full_mode
}

# ==========================================================
# driver update
# ==========================================================

update_drivers() {
    header

    warn "Updating NVIDIA drivers"

    echo
    echo "This uses Ubuntu recommended drivers."
    echo
    echo "Useful recovery:"
    echo "    $SCRIPT_NAME doctor"
    echo "    $SCRIPT_NAME reset"
    echo

    confirm_action \
        "Proceed with driver update?" \
        || exit 1

    run "Refreshing package lists" \
        sudo apt update

    info "Recommended drivers"

    ubuntu-drivers devices || true

    echo

    read -rp "Install recommended drivers? [y/N]: " ans

    if [[ "$ans" =~ ^[Yy]$ ]]; then
        run "Installing recommended drivers" \
            sudo ubuntu-drivers autoinstall

        run "Updating initramfs" \
            sudo update-initramfs -u

        REBOOT_REQUIRED=true

        good "Driver update complete"
    else
        warn "Skipped installation"
    fi
}

# ==========================================================
# usage
# ==========================================================

usage() {
cat <<EOF

$SCRIPT_NAME - NVIDIA Power State Manager

USAGE:
    $SCRIPT_NAME <command>

COMMANDS:

    MODES
        off         Disable NVIDIA aggressively
        lowpower    CUDA usable, desktop on iGPU
        full        Full NVIDIA mode
        reset       Restore sane Ubuntu defaults

    DIAGNOSTICS
        status      Compact system overview
        diagnose    Verbose diagnostics
        doctor      Detect broken/stale configuration

    DRIVER
        update      Install recommended drivers

EXAMPLES:
    $SCRIPT_NAME off
    $SCRIPT_NAME lowpower
    $SCRIPT_NAME status
    $SCRIPT_NAME doctor

IMPORTANT:
    Most mode changes require reboot.

RECOVERY:
    If things become inconsistent:

        1. $SCRIPT_NAME doctor
        2. $SCRIPT_NAME reset
        3. reboot

EOF
}

# ==========================================================
# main
# ==========================================================

main() {
    require_cmd lspci

    if ! gpu_present; then
        bad "No NVIDIA GPU detected"
        exit 1
    fi

    detect_gpu_bdf
    detect_audio_bdf

    case "${1:-}" in
        off)
            off_mode
            ;;
        lowpower)
            lowpower_mode
            ;;
        full)
            full_mode
            ;;
        reset)
            reset_mode
            ;;
        status)
            status
            ;;
        diagnose)
            diagnose
            ;;
        doctor)
            doctor
            ;;
        update)
            update_drivers
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            exit 1
            ;;
    esac

    echo

    if $REBOOT_REQUIRED; then
        warn "Reboot strongly recommended"
    fi
}

main "$@"