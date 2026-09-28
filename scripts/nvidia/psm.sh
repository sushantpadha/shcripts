#!/usr/bin/env bash
# Switch the NVIDIA GPU between fully off and PRIME on-demand. Status is read-only.
#
# Run it and pick from the menu, or pass the mode: psm.sh [status|off|on-demand]
#
#   status     read-only checks. Never wakes the GPU (no nvidia-smi).
#   off        prime-select intel (blacklists the nvidia modules, rebuilds initramfs),
#              plus a udev rule so the driverless GPU can power down to D3cold, and
#              `install nvidia /bin/false` so nothing (e.g. nvidia_uvm) pulls the driver back in.
#   on-demand  prime-select on-demand (desktop on iGPU, dGPU sleeps via RTD3 until used),
#              nvidia-powerd on, RTD3 config (nvidia-runtimepm.conf) ensured.
#
# Both modes also remove leftovers from older nvidia scripts. Every file changed or removed
# (including the ones prime-select rewrites) is backed up to /var/backups/psm/<time>/ first.
# RESTORE.sh there is updated after every step, so it is valid even after a crash or Ctrl-C.
# Never remove /etc/u-d-c-nvidia-runtimepm-override: it is what enables RTD3 on this machine.
# Reboot after applying, then run status.
#
# Recovery:
#   sudo prime-select on-demand && sudo reboot           (safe default)
#   sudo bash /var/backups/psm/<time>/RESTORE.sh && sudo reboot   (undo one run)
# Notes: scripts/nvidia/MEREAD.md

set -uo pipefail

RED="\033[1;31m" GRN="\033[1;32m" YLW="\033[1;33m" CYN="\033[1;36m" DIM="\033[2m" RST="\033[0m"
hdr()  { echo -e "\n${CYN}== $* ==${RST}"; }
pass() { echo -e "  ${GRN}PASS${RST}  $1"; }
warn() { echo -e "  ${YLW}WARN${RST}  $1"; [ -n "${2:-}" ] && echo -e "        ${DIM}hint: $2${RST}"; return 0; }
info() { echo -e "  ${DIM}....${RST}  $*"; }

OFF_RULE=/etc/udev/rules.d/80-psm-nvidia-off.rules
OFF_CONF=/etc/modprobe.d/psm-nvidia-off.conf
RTD3_CONF=/lib/modprobe.d/nvidia-runtimepm.conf
PRIME_FILES=(/etc/prime-discrete /lib/modprobe.d/blacklist-nvidia.conf /lib/modprobe.d/nvidia-kms.conf "$RTD3_CONF")
LEFTOVER_FILES=(
    /etc/udev/rules.d/71-nvidia.rules            # old override: disabled nvidia-drm/uvm autoload
    /etc/udev/rules.d/99-nvidia-disable.rules
    /etc/modprobe.d/blacklist-nvidia.conf
)
LEFTOVER_UNITS=(nvidia-power-cap.service nvidia-off-pm.service)

# NVIDIA PCI functions from sysfs. GPU = first display-class one.
NV=() GPU=""
for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor")" = 0x10de ] || continue
    NV+=("$(basename "$d")")
    [[ -z "$GPU" && "$(cat "$d/class")" == 0x03* ]] && GPU=$(basename "$d")
done

prime_mode() { prime-select query 2>/dev/null || echo unknown; }
kernel_args() { grep -oE '\S*(nvidia|nouveau)\S*' "$1" | tr '\n' ' '; }
grub_args() {
    grep -hE '^GRUB_CMDLINE_LINUX(_DEFAULT)?=' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null |
        grep -oE '\S*(nvidia|nouveau)\S*' | tr '\n' ' '
    return 0
}

leftovers() {
    local f u
    for f in "${LEFTOVER_FILES[@]}"; do [ -e "$f" ] && echo "$f"; done
    for u in "${LEFTOVER_UNITS[@]}"; do [ -e "/etc/systemd/system/$u" ] && echo "/etc/systemd/system/$u"; done
    return 0
}

# ── status ────────────────────────────────────────────────────────────────────

status() {
    local mode s f
    mode=$(prime_mode)

    hdr "Mode"
    case "$mode" in
        on-demand|intel) pass "prime-select: $mode" ;;
        *) warn "prime-select: $mode" "run psm.sh and pick off or on-demand" ;;
    esac
    [ -z "$GPU" ] && { warn "no NVIDIA GPU on the PCI bus" "check BIOS / lspci -D | grep -i nvidia"; return; }
    info "GPU $GPU, NVIDIA functions: ${NV[*]}"

    hdr "Kernel args"
    s=$(kernel_args /proc/cmdline)
    [ -z "$s" ] && pass "none in /proc/cmdline" \
        || warn "running kernel has: $s" "old GRUB args override prime-select; see /etc/default/grub"
    s=$(grub_args)
    [ -z "$s" ] && pass "none in GRUB config" \
        || warn "GRUB config has: $s" "remove them from /etc/default/grub (or grub.d/*.cfg), sudo update-grub, reboot"

    hdr "Driver"
    s=$(lsmod | awk '/^(nvidia|nouveau)/{printf "%s ", $1}')
    f=$(basename "$(readlink "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null)" 2>/dev/null)
    lsmod | grep -q '^nouveau' && warn "nouveau loaded" "nouveau should be blacklisted by the driver package"
    if [ "$mode" = intel ]; then
        [ -z "$s" ] && pass "no nvidia modules loaded" || warn "loaded: $s" "reboot; if it stays, check initramfs: sudo update-initramfs -u"
        [ -z "$f" ] && pass "GPU has no driver bound" || warn "GPU bound to: $f" "reboot after psm.sh off"
        [ -e "$OFF_RULE" ] && pass "power rule present: $OFF_RULE" || warn "missing $OFF_RULE" "rerun psm.sh off; without it the GPU stays powered"
        [ -e "$OFF_CONF" ] && pass "driver load blocked: $OFF_CONF" || warn "missing $OFF_CONF" "rerun psm.sh off; without it nvidia_uvm can pull the driver in"
        systemctl is-enabled -q nvidia-powerd 2>/dev/null && warn "nvidia-powerd enabled" "rerun psm.sh off" || pass "nvidia-powerd disabled"
    else
        [ -n "$s" ] && pass "loaded: $s" || warn "no nvidia modules loaded" "reboot; if it stays, check blacklists: grep -r nvidia /etc/modprobe.d /lib/modprobe.d"
        [ "$f" = nvidia ] && pass "GPU bound to nvidia" || warn "GPU driver: ${f:-none}" "reboot; then sudo dmesg | grep -i nvidia"
        s=$(awk '/DynamicPowerManagement:/{print $2}' /proc/driver/nvidia/params 2>/dev/null)
        [[ "$s" == 2 || "$s" == 3 ]] && pass "DynamicPowerManagement=$s (RTD3 on)" \
            || warn "DynamicPowerManagement=${s:-?}" "rerun psm.sh on-demand (writes /lib/modprobe.d/nvidia-runtimepm.conf), reboot"
        for f in "$OFF_RULE" "$OFF_CONF"; do [ -e "$f" ] && warn "off-mode file still present: $f" "rerun psm.sh on-demand"; done
        [ -e "$RTD3_CONF" ] && pass "$RTD3_CONF present" || warn "missing $RTD3_CONF" "rerun psm.sh on-demand, reboot"
        systemctl is-enabled -q nvidia-powerd 2>/dev/null && pass "nvidia-powerd enabled" || warn "nvidia-powerd not enabled" "sudo systemctl enable --now nvidia-powerd"
    fi

    hdr "Power (sysfs, does not wake the GPU)"
    for f in "${NV[@]}"; do
        local p=/sys/bus/pci/devices/$f/power ctl rt ps
        ctl=$(cat "$p/control") rt=$(cat "$p/runtime_status")
        ps=$(cat "/sys/bus/pci/devices/$f/power_state" 2>/dev/null || echo ?)
        [ "$ctl" = auto ] && pass "$f control=auto" || warn "$f control=$ctl" "runtime PM blocked: echo auto | sudo tee $p/control"
        if [ "$rt" = suspended ]; then pass "$f $rt ($ps)"
        else warn "$f $rt ($ps)" "something is using it, see below (idle GPU should suspend within ~15s)"; fi
    done
    if [ "$(cat "/sys/bus/pci/devices/$GPU/power/runtime_status")" = active ]; then
        hdr "Processes holding the GPU"
        local nodes
        shopt -s nullglob; nodes=(/dev/nvidia* /dev/dri/by-path/pci-"$GPU"-*); shopt -u nullglob
        [ ${#nodes[@]} -gt 0 ] && fuser -v "${nodes[@]}" 2>&1 | sed 's/^/  /' || info "none visible"
        [ "$EUID" -ne 0 ] && info "only your processes shown; sudo psm.sh status shows all"
    fi

    hdr "Leftovers from old scripts"
    s=$(leftovers)
    [ -z "$s" ] && pass "none" || while read -r f; do warn "$f" "rerun psm.sh off or on-demand to back up and remove"; done <<<"$s"
    return 0
}

# ── apply ─────────────────────────────────────────────────────────────────────

BK="" STEP="" RESTORE=() PRIME_RESTORE=()

# RESTORE.sh = prime-select back, then prime-select's own files, then everything else
save_restore() { [ -n "$BK" ] && printf '%s\n' "set -x" "${PRIME_RESTORE[@]}" "${RESTORE[@]}" \
    "update-initramfs -u" "udevadm control --reload" "systemctl daemon-reload" > "$BK/RESTORE.sh"; return 0; }
undo() { RESTORE+=("$1"); save_restore; }

recovery() {
    echo -e "\n${CYN}Recovery${RST}"
    [ -n "$BK" ] && echo "  backups:  $BK" && echo "  undo run: sudo bash $BK/RESTORE.sh && sudo reboot"
    echo "  fallback: sudo prime-select on-demand && sudo reboot"
    echo "  check:    bash $0 status"
    echo "  notes:    $(dirname "$0")/MEREAD.md"
}

failed() {
    trap - ERR INT TERM HUP
    echo -e "\n${RED}FAILED${RST} ($2) at line $1 during: $STEP"
    save_restore
    recovery
    exit 1
}

backup() { mkdir -p "$BK$(dirname "$1")"; cp -a "$1" "$BK$1"; }

remove_file() {
    STEP="removing $1"; echo "  - rm $1"
    backup "$1"; rm -f "$1"
    undo "cp -a '$BK$1' '$1'"
}

# write_file <path> <content>: back up or mark for removal, then write
write_file() {
    STEP="writing $1"; echo "  - write $1"
    if [ -e "$1" ]; then backup "$1"; undo "cp -a '$BK$1' '$1'"; else undo "rm -f '$1'"; fi
    printf '%s\n' "$2" > "$1"
}

apply() {
    local want=$1 prime cur f u
    [ "$want" = off ] && prime=intel || prime=on-demand
    cur=$(prime_mode)
    mapfile -t LEFT < <(leftovers)

    hdr "Plan: $want"
    echo "  - prime-select $prime  (now: $cur; rewrites /lib/modprobe.d)"
    echo "  - update-initramfs -u  (~1 min, checked; prime-select ignores its errors)"
    if [ "$want" = off ]; then
        echo "  - write $OFF_RULE  (power/control=auto so the unbound GPU can reach D3cold)"
        echo "  - write $OFF_CONF  (install nvidia /bin/false: nothing can load the driver)"
        echo "  - systemctl disable nvidia-powerd"
    else
        for f in "$OFF_RULE" "$OFF_CONF"; do [ -e "$f" ] && echo "  - rm $f"; done
        echo "  - systemctl enable nvidia-powerd"
        echo "  - ensure $RTD3_CONF (RTD3 on)"
    fi
    for f in "${LEFT[@]}"; do echo "  - back up + remove leftover $f"; done
    [ -n "$(grub_args)" ] && warn "GRUB config has: $(grub_args)" \
        "not touched here. Remove them from /etc/default/grub, sudo update-grub"
    echo -e "  backups go to /var/backups/psm/<time>/"

    read -rp "Proceed? [y/N] " a
    [[ "$a" =~ ^[yY]$ ]] || { echo "aborted, nothing changed"; exit 0; }

    set -Ee
    trap 'failed $LINENO error' ERR
    trap 'failed $LINENO interrupted' INT TERM HUP
    BK=/var/backups/psm/$(date +%F_%H-%M-%S)
    mkdir -p "$BK"
    save_restore
    hdr "Applying"

    for f in "${LEFT[@]}"; do
        u=$(basename "$f")
        if [[ "$f" == *.service ]]; then
            STEP="disabling $u"; echo "  - systemctl disable --now $u"
            systemctl disable --now "$u"
            remove_file "$f"
            undo "systemctl daemon-reload"
            undo "systemctl enable '$u'"
        else
            remove_file "$f"
        fi
    done

    if [ "$want" = off ]; then
        write_file "$OFF_RULE" '# psm.sh off mode: let the NVIDIA GPU (no driver bound) runtime-suspend to D3cold.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", TEST=="power/control", ATTR{power/control}="auto"'
        write_file "$OFF_CONF" '# psm.sh off mode: block the nvidia module, also when pulled in as a dependency (nvidia_uvm etc).
install nvidia /bin/false'
        STEP="disabling nvidia-powerd"; echo "  - systemctl disable nvidia-powerd"
        systemctl is-enabled -q nvidia-powerd 2>/dev/null && undo "systemctl enable nvidia-powerd"
        systemctl disable nvidia-powerd 2>/dev/null || true
    else
        for f in "$OFF_RULE" "$OFF_CONF"; do [ -e "$f" ] && remove_file "$f"; done
        STEP="enabling nvidia-powerd"; echo "  - systemctl enable nvidia-powerd"
        systemctl is-enabled -q nvidia-powerd 2>/dev/null || undo "systemctl disable nvidia-powerd"
        systemctl enable nvidia-powerd
    fi

    STEP="reloading udev + systemd"
    udevadm control --reload
    systemctl daemon-reload

    # back up what prime-select rewrites; RESTORE puts it back after re-running prime-select
    STEP="backing up prime-select files"
    [ "$cur" != unknown ] && PRIME_RESTORE+=("prime-select '$cur'")
    for f in "${PRIME_FILES[@]}"; do
        if [ -e "$f" ]; then backup "$f"; PRIME_RESTORE+=("cp -a '$BK$f' '$f'")
        else PRIME_RESTORE+=("rm -f '$f'"); fi
    done
    save_restore

    STEP="prime-select $prime"; echo "  - prime-select $prime"
    prime-select "$prime"
    # prime-select exits 0 even when it fails, so check what it actually did
    [ "$(prime_mode)" = "$prime" ] || { STEP="prime-select $prime (query says $(prime_mode))"; false; }

    if [ "$want" = on-demand ] && [ ! -e "$RTD3_CONF" ]; then
        # prime-select skips this when /run/nvidia_runtimepm_supported is missing
        STEP="writing $RTD3_CONF"; echo "  - write $RTD3_CONF"
        echo 'options nvidia "NVreg_DynamicPowerManagement=0x02"' > "$RTD3_CONF"
    fi

    STEP="update-initramfs -u"; echo "  - update-initramfs -u"
    update-initramfs -u

    trap - ERR INT TERM HUP
    save_restore
    echo -e "\n${GRN}Done.${RST} Reboot, then run: bash $0 status"
    recovery
}

# ── menu ──────────────────────────────────────────────────────────────────────

choice=${1:-}
if [ -z "$choice" ]; then
    echo -e "${CYN}NVIDIA power switch${RST}  (now: $(prime_mode))"
    echo "  1) status     read-only checks"
    echo "  2) off        GPU fully off (prime-select intel)"
    echo "  3) on-demand  GPU sleeps until used (prime-select on-demand)"
    echo "  q) quit"
    read -rp "Pick [1]: " choice
fi

case "${choice:-1}" in
    1|status) status ;;
    2|off|3|on-demand)
        [[ "$choice" == 2 || "$choice" == off ]] && m=off || m=on-demand
        [ -z "$GPU" ] && { echo -e "${RED}No NVIDIA GPU found on the PCI bus.${RST}"; exit 1; }
        [ "$EUID" -eq 0 ] || exec sudo bash "$0" "$m"
        apply "$m" ;;
    q|quit) ;;
    *) echo "unknown choice: $choice"; exit 1 ;;
esac
