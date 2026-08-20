#!/usr/bin/env bash
set -euo pipefail

GRUB="/etc/default/grub"

NVIDIA_BLACKLIST="modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nvidia_peermem"
NOUVEAU_ARG="nouveau.modeset=0"

usage() {
    echo "Usage: sudo $0 {off|on-demand|status}"
    exit 1
}

require_root() {
    [[ $EUID -eq 0 ]] || {
        echo "Run with sudo."
        exit 1
    }
}

get_cmdline() {
    sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)".*/\1/p' "$GRUB"
}

set_cmdline() {
    local cmdline="$1"

    sed -i \
        "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\"|" \
        "$GRUB"
}

remove_nvidia_args() {
    local cmdline
    cmdline="$(get_cmdline)"

    cmdline="$(
        printf '%s\n' "$cmdline" |
        sed -E \
            -e 's/(^| )modprobe\.blacklist=[^ ]*(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm|nvidia_peermem)[^ ]*( |$)/\1\3/g' \
            -e 's/(^| )nouveau\.modeset=0( |$)/\1\2/g'
    )"

    set_cmdline "$(echo "$cmdline" | xargs)"
}

off() {
    echo "Configuring NVIDIA OFF..."

    local cmdline
    cmdline="$(get_cmdline)"

    remove_nvidia_args
    cmdline="$(get_cmdline)"

    [[ "$cmdline" == *"$NVIDIA_BLACKLIST"* ]] ||
        cmdline="$cmdline $NVIDIA_BLACKLIST"

    [[ "$cmdline" == *"$NOUVEAU_ARG"* ]] ||
        cmdline="$cmdline $NOUVEAU_ARG"

    set_cmdline "$(echo "$cmdline" | xargs)"

    update-grub

    systemctl disable --now nvidia-powerd.service 2>/dev/null || true

    echo
    echo "NVIDIA will be blacklisted after reboot."
    echo "nvidia-powerd disabled."
    echo
    echo "GRUB:"
    get_cmdline
    echo
    echo "Reboot to apply."
}

on_demand() {
    echo "Configuring NVIDIA ON-DEMAND..."

    remove_nvidia_args
    update-grub

    if [[ "$(prime-select query 2>/dev/null || true)" != "on-demand" ]]; then
        prime-select on-demand
    fi

    systemctl enable nvidia-powerd.service
    systemctl restart nvidia-powerd.service

    echo
    echo "NVIDIA configured for PRIME on-demand."
    echo "nvidia-powerd enabled."
    echo
    echo "GRUB:"
    get_cmdline
    echo
    echo "Reboot recommended to apply cleanly."
}

status() {
    echo "=== GRUB ==="
    get_cmdline

    echo
    echo "=== PRIME ==="
    prime-select query 2>/dev/null || true

    echo
    echo "=== NVIDIA modules ==="
    if lsmod | grep -q '^nvidia'; then
        echo "loaded"
    else
        echo "not loaded"
    fi

    echo
    echo "=== nvidia-powerd ==="
    systemctl is-enabled nvidia-powerd.service 2>/dev/null || true
    systemctl is-active nvidia-powerd.service 2>/dev/null || true

    echo
    echo "=== Runtime PM ==="
    for f in \
        /sys/bus/pci/devices/0000:01:00.0/power/control \
        /sys/bus/pci/devices/0000:01:00.0/power/runtime_status
    do
        [[ -f "$f" ]] && echo "$f: $(cat "$f")"
    done

    echo
    echo "=== NVIDIA ==="
    nvidia-smi --query-gpu=pstate,power.draw --format=csv 2>/dev/null ||
        echo "NVIDIA driver unavailable"
}

[[ $# -eq 1 ]] || usage

case "$1" in
    off)
        require_root
        off
        ;;
    on-demand)
        require_root
        on_demand
        ;;
    status)
        status
        ;;
    *)
        usage
        ;;
esac