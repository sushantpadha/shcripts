#!/usr/bin/env bash
# Read-only NVIDIA / CUDA / driver / Secure Boot diagnosis (no arg = full doctor, "status" = quick)
set -u

RED="\033[1;31m"
GRN="\033[1;32m"
YLW="\033[1;33m"
CYN="\033[1;36m"
RST="\033[0m"

sudo -v || exit 1

_hdr() {
    echo
    echo -e "${CYN}=== $* ===${RST}"
}

run() {
    echo -e "${YLW}\$ $*${RST}"
    "$@" 2>&1 || true
}

doctor() {
    _hdr "Kernel / Session"
    run uname -r
    run bash -c 'echo "session: $XDG_SESSION_TYPE / $XDG_CURRENT_DESKTOP"'
    run prime-select query

    _hdr "CUDA Toolkit"
    run nvcc --version
    run bash -c 'dpkg -l "cuda-toolkit-*" 2>/dev/null | grep "^ii" || echo "no cuda-toolkit package installed"'

    _hdr "NVIDIA Driver Packages"
    run bash -c 'dpkg -l | grep -E "nvidia|cuda" || true'
    run bash -c '
        pkgs=$(dpkg-query -W -f "\${db:Status-Abbrev} \${binary:Package}\n" \
            "nvidia-driver-*" "nvidia-dkms-*" "nvidia-kernel-common-*" "libnvidia-gl-*" "cuda-toolkit-*" 2>/dev/null |
            awk "\$1 == \"ii\" {print \$2}")
        [ -n "$pkgs" ] && apt-cache policy $pkgs || echo "no nvidia packages installed"
    '

    _hdr "NVIDIA Driver"
    run nvidia-smi
    run bash -c '
        nvidia-smi --query-gpu=pstate,power.draw,temperature.gpu,utilization.gpu \
            --format=csv
    '

    _hdr "Kernel Modules / DKMS"
    run bash -c 'lsmod | grep nvidia || true'
    run bash -c '
        modinfo nvidia 2>&1 |
            grep -E "filename|version|signer|sig_key|sig_id|vermagic"
    '
    run sudo dkms status

    _hdr "Secure Boot / Module Signing"
    run mokutil --sb-state
    run bash -c '
        sudo mokutil --list-enrolled |
            grep -iE "nvidia|ubuntu|canonical" || true
    '
    run bash -c '
        mokutil --test-key /var/lib/shim-signed/mok/MOK.der 2>&1 || true
    '

    _hdr "NVIDIA Power Management"
    run systemctl status nvidia-powerd --no-pager
    run bash -c '
        pkg=$(dpkg -S /usr/bin/nvidia-powerd 2>/dev/null | cut -d: -f1)
        echo "nvidia-powerd owned by: ${pkg:-no package}"
        [ -n "$pkg" ] || exit 0
        dpkg -L "$pkg" | grep -E "powerd|systemd"
        cat "/usr/share/doc/$pkg/nvidia-powerd.service" 2>/dev/null
    '

    _hdr "GPU Runtime Power"
    run bash -c '
        for f in /proc/driver/nvidia/gpus/*/power; do
            echo "--- $f"
            sudo cat "$f"
        done
    '
    run bash -c '
        for f in /sys/bus/pci/devices/*/power/runtime_status; do
            if lspci -s "$(basename "$(dirname "$(dirname "$f")")")" 2>/dev/null |
                grep -qi nvidia; then
                echo "$f: $(cat "$f")"
            fi
        done
    '

    _hdr "NVIDIA / Secure-Boot Kernel Messages"
    run bash -c '
        sudo dmesg |
            grep -iE "nvidia|nouveau|secure boot|lockdown|module verification|key rejected" |
            tail -100
    '
}

status() {
    _hdr "Quick NVIDIA Status"

    run uname -r
    run prime-select query
    run nvidia-smi
    run bash -c 'lsmod | grep nvidia || true'
    run sudo dkms status
    run systemctl is-active nvidia-powerd
    run bash -c '
        nvidia-smi --query-gpu=pstate,power.draw \
            --format=csv 2>&1 || true
    '

    run mokutil --sb-state
}

usage() {
    echo "Usage: $0 {status|doctor}"
    echo
    echo "  status   Quick NVIDIA/GPU status"
    echo "  doctor   Full read-only NVIDIA/CUDA diagnosis"
}

case "${1:-doctor}" in
    status) status ;;
    doctor) doctor ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac