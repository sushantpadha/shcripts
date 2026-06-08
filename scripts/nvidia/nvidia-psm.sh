#!/usr/bin/env bash
# Manage NVIDIA power state, print status, diagnose issues

# ==========================================================
# nvidia-psm  --  NVIDIA Power State Manager
#
# Target: Ubuntu 24, hybrid laptop (AMD iGPU + NVIDIA dGPU)
# Tested: HP Omen 16 / Ryzen 7 7840HS / RTX 4050 Mobile
#
# MODES:    off | lowpower | full | reset
# DIAG:     status | diagnose | doctor
# DRIVER:   update
# FLAGS:    -i / --interactive   confirm each step before running
# ==========================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
INTERACTIVE=false
REBOOT_REQUIRED=false

# Populated by detect_gpu_bdf / detect_audio_bdf
GPU_BDF=""
AUDIO_BDF=""

SERVICES=(
    nvidia-persistenced.service
    nvidia-powerd.service
    nvidia-hibernate.service
    nvidia-resume.service
    nvidia-suspend.service
)

# Persistent files this script owns
BLACKLIST_CONF="/etc/modprobe.d/blacklist-nvidia.conf"
UDEV_DISABLE_RULE="/etc/udev/rules.d/99-nvidia-disable.rules"
LOWPOWER_SERVICE="/etc/systemd/system/nvidia-power-cap.service"
OFF_PM_SERVICE="/etc/systemd/system/nvidia-off-pm.service"

# ---------- colours ----------
RED="\033[1;31m"
GRN="\033[1;32m"
YLW="\033[1;33m"
BLU="\033[1;34m"
CYN="\033[1;36m"
DIM="\033[2m"
BLD="\033[1m"
RST="\033[0m"

# ==========================================================
# error trap
# ==========================================================

trap '{
    echo
    _bad "Script failed at line $LINENO"
    echo
    _warn "Run:  $SCRIPT_NAME doctor   to inspect system state"
    _warn "Run:  $SCRIPT_NAME reset    to recover"
    echo
}' ERR

# ==========================================================
# logging primitives
# ==========================================================

_info() { echo -e "${BLU}  *${RST} $*"; }
_good() { echo -e "${GRN}  +${RST} $*"; }
_warn() { echo -e "${YLW}  !${RST} $*"; }
_bad()  { echo -e "${RED}  x${RST} $*"; }
_dim()  { echo -e "${DIM}    $*${RST}"; }
_hdr()  { echo -e "\n${BLD}${CYN}$*${RST}"; }
_sep()  { echo -e "${DIM}----------------------------------------------------${RST}"; }

# Compact two-column key/value line
_kv() {
    # _kv "label" "value" [color]
    local col="${3:-$RST}"
    printf "  ${DIM}%-24s${RST} ${col}%s${RST}\n" "$1" "$2"
}

# PASS / WARN / FAIL badge
_badge() {
    case "$1" in
        PASS) echo -e "${GRN}[PASS]${RST}" ;;
        WARN) echo -e "${YLW}[WARN]${RST}" ;;
        FAIL) echo -e "${RED}[FAIL]${RST}" ;;
        *)    echo -e "${DIM}[ ?? ]${RST}" ;;
    esac
}

# ==========================================================
# run() -- execute a command, optionally with interactive gate
# ==========================================================
# Usage: run "Human description" cmd arg arg...
#
# In interactive mode: prints the command, asks [y/s/q].
#   y = run it
#   s = skip this step
#   q = abort script
# In non-interactive mode: prints description + command, runs it.

run() {
    local desc="$1"; shift
    local cmd_str="$*"

    echo
    _info "$desc"
    _dim "$ $cmd_str"

    if $INTERACTIVE; then
        echo -ne "  ${YLW}Run this step? [Y/s/q]:${RST} "
        local ans
        read -r ans
        ans="${ans:-y}"
        case "$ans" in
            [Yy]*) ;;
            [Ss]*)
                _warn "Skipped."
                return 0
                ;;
            [Qq]*)
                _warn "Aborted by user."
                exit 1
                ;;
            *)
                _warn "Skipped (unrecognised input)."
                return 0
                ;;
        esac
    fi

    "$@"
}

# ==========================================================
# confirm_action -- top-level mode gate (always shown)
# ==========================================================

confirm_action() {
    local prompt="$1"
    echo
    _warn "$prompt"
    echo -ne "  Continue? [y/N]: "
    local ans
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ==========================================================
# helpers
# ==========================================================

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        _bad "Missing required command: $1"
        exit 1
    }
}

gpu_present() {
    lspci | grep -qi nvidia
}

gpu_sysfs()             { echo "/sys/bus/pci/devices/$GPU_BDF"; }
gpu_power_control_path(){ echo "$(gpu_sysfs)/power/control"; }

runtime_status() {
    cat "$(gpu_sysfs)/power/runtime_status" 2>/dev/null || echo "unknown"
}

power_control() {
    cat "$(gpu_power_control_path)" 2>/dev/null || echo "unknown"
}

renderer() {
    glxinfo 2>/dev/null | grep -i "OpenGL renderer" | sed 's/OpenGL renderer string: //' || echo "unknown"
}

# ==========================================================
# power_snapshot -- averaged power draw over ~3 seconds
# ==========================================================
# Sources tried in order:
#   1. turbostat --num_iterations 3  (CPU package + core + uncore RAPL)
#   2. RAPL sysfs directly           (fallback if turbostat absent)
#   3. nvidia-smi                    (dGPU, if driver active)
#   4. sensors                       (board/battery info)

power_snapshot() {
    _hdr "Power Draw (3-second average)"
    _sep

    # --- turbostat ---
    if command -v turbostat >/dev/null 2>&1; then
        local ts_out
        # --num_iterations 3: sample 3 times (1s apart by default) then exit
        # --Summary: one aggregate row, not per-core
        # --quiet: suppress header noise to stderr
        # We capture stdout only; parse the two-line header+data output
        ts_out=$(sudo turbostat --Summary --quiet --num_iterations 3 2>/dev/null) || true

        if [[ -n "$ts_out" ]]; then
            # turbostat Summary output:
            #   line 1: column headers  e.g.  Avg_MHz  Busy%  Bzy_MHz  TSC_MHz  IPC  IRQ  SMI  PkgWatt  CorWatt  PkgTmp
            #   line 2: values
            local headers values
            headers=$(echo "$ts_out" | head -n1)
            values=$(echo  "$ts_out" | tail -n1)

            # Parse into array using awk -- print each header:value pair
            local parsed
            parsed=$(paste \
                <(echo "$headers" | tr -s ' \t' '\n') \
                <(echo "$values"  | tr -s ' \t' '\n') \
                | awk -F'\t' '{printf "%-16s %s\n", $1, $2}')

            # Print only the fields we care about
            local interesting=(PkgWatt CorWatt GFXWatt RAMWatt PkgTmp Busy% Avg_MHz)
            echo "$parsed" | while IFS= read -r line; do
                local key val
                key=$(echo "$line" | awk '{print $1}')
                val=$(echo "$line" | awk '{print $2}')
                for k in "${interesting[@]}"; do
                    if [[ "$key" == "$k" ]]; then
                        case "$key" in
                            PkgWatt) _kv "CPU package"     "${val} W" "$YLW" ;;
                            CorWatt) _kv "CPU cores"       "${val} W" ;;
                            GFXWatt) _kv "iGPU (GFX)"     "${val} W" ;;
                            RAMWatt) _kv "RAM"             "${val} W" ;;
                            PkgTmp)  _kv "CPU temp"        "${val} C" ;;
                            "Busy%") _kv "CPU busy"        "${val} %" ;;
                            Avg_MHz) _kv "CPU avg freq"    "${val} MHz" ;;
                        esac
                    fi
                done
            done
        else
            _warn "turbostat returned no output (need root?)"
            _rapl_fallback
        fi
    else
        _warn "turbostat not found -- falling back to RAPL sysfs"
        _rapl_fallback
    fi

    _sep

    # --- nvidia-smi (dGPU) ---
    if lsmod | grep -q "^nvidia" && command -v nvidia-smi >/dev/null 2>&1; then
        local smi
        smi=$(nvidia-smi \
            --query-gpu=power.draw,temperature.gpu,utilization.gpu \
            --format=csv,noheader,nounits 2>/dev/null) || true
        if [[ -n "$smi" ]]; then
            IFS=',' read -r pwr tmp util <<< "$smi"
            _kv "dGPU power"    "${pwr// /} W" "$YLW"
            _kv "dGPU temp"     "${tmp// /} C"
            _kv "dGPU util"     "${util// /} %"
        fi
    else
        _kv "dGPU"  "driver not active (suspended or off)"  "$GRN"
    fi

    _sep

    # --- battery discharge rate (if on battery) ---
    local bat_path
    bat_path=$(find /sys/class/power_supply -maxdepth 1 -name 'BAT*' | head -n1 || true)
    if [[ -n "$bat_path" ]]; then
        local status_val current_ua voltage_uv
        status_val=$(cat "$bat_path/status"         2>/dev/null || echo "unknown")
        current_ua=$(cat "$bat_path/current_now"    2>/dev/null || echo "0")
        voltage_uv=$(cat "$bat_path/voltage_now"    2>/dev/null || echo "0")

        if [[ "$current_ua" -gt 0 && "$voltage_uv" -gt 0 ]] 2>/dev/null; then
            # Power = V * I, both in micro-units -> result in W
            local power_mw
            power_mw=$(awk "BEGIN {printf \"%.1f\", ($voltage_uv * $current_ua) / 1e12}")
            _kv "battery"  "${status_val} @ ${power_mw} W"
        else
            _kv "battery"  "$status_val"
        fi
    fi

    _sep
}

# RAPL sysfs fallback (no turbostat)
_rapl_fallback() {
    local rapl_base="/sys/class/powercap"
    if [[ ! -d "$rapl_base" ]]; then
        _warn "RAPL sysfs not available"
        return
    fi

    # Read each RAPL domain: intel-rapl:0 = package, intel-rapl:0:0 = core, etc.
    # We take two readings 2 seconds apart to compute average power
    local tmp1 tmp2
    tmp1=$(mktemp)
    tmp2=$(mktemp)

    find "$rapl_base" -name "energy_uj" 2>/dev/null | sort > "$tmp1"
    sleep 2
    find "$rapl_base" -name "energy_uj" 2>/dev/null | sort > "$tmp2"

    paste "$tmp1" "$tmp2" | while IFS=$'\t' read -r path1 path2; do
        [[ "$path1" == "$path2" ]] || continue
        local e1 e2 domain_path domain_name watts
        e1=$(cat "$path1" 2>/dev/null || echo 0)
        e2=$(cat "$path2" 2>/dev/null || echo 0)
        domain_path=$(dirname "$path1")
        domain_name=$(cat "$domain_path/name" 2>/dev/null || basename "$domain_path")
        watts=$(awk "BEGIN {printf \"%.2f\", ($e2 - $e1) / 2e6}")
        _kv "RAPL $domain_name" "${watts} W"
    done

    rm -f "$tmp1" "$tmp2"
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
        _bad "Could not detect NVIDIA GPU PCI address"
        exit 1
    fi

    GPU_BDF="$detected"

    echo
    _sep
    _kv "Detected GPU BDF" "$GPU_BDF" "$CYN"
    _dim "Verify: lspci -D | grep -Ei 'VGA|3D|NVIDIA'"
    _sep

    echo -ne "\n  Looks correct? [Y/n]: "
    local ans; read -r ans; ans="${ans:-y}"
    [[ "$ans" =~ ^[Yy]$ ]] || { _warn "Aborting."; exit 1; }
}

detect_audio_bdf() {
    AUDIO_BDF=$(
        lspci -D |
        grep -i nvidia |
        grep -i audio |
        awk '{print $1}' |
        head -n1
    ) || true
    [[ -n "${AUDIO_BDF:-}" ]] || AUDIO_BDF="none"
}

# ==========================================================
# write_verified -- write a file, cat it back for confirmation
# ==========================================================
# Usage: write_verified "/path/to/file" <<'EOF'
#        content
#        EOF

write_verified() {
    local path="$1"
    local content
    content="$(cat)"          # reads stdin

    echo "$content" | sudo tee "$path" >/dev/null

    echo
    _info "Wrote ${BLD}$path${RST} -- contents:"
    _sep
    sudo cat "$path" | while IFS= read -r line; do
        _dim "$line"
    done
    _sep
}

# ==========================================================
# verify_initramfs -- check blacklist is embedded after rebuild
# ==========================================================

verify_initramfs() {
    echo
    _hdr "Initramfs Sanity Check"
    _sep

    local img="/boot/initrd.img-$(uname -r)"
    local hits

    hits=$(lsinitramfs "$img" 2>/dev/null | grep -i nvidia || true)

    if [[ -z "$hits" ]]; then
        _kv "nvidia in initramfs" "none found" "$GRN"
        printf "  %s  No NVIDIA modules embedded -- good for OFF mode.\n" "$(_badge PASS)"
    else
        printf "  %s  NVIDIA entries found in initramfs:\n" "$(_badge WARN)"
        echo "$hits" | while IFS= read -r line; do
            _dim "$line"
        done
        echo
        _warn "This may cause modules to load before blacklist is consulted."
        _warn "If GPU persists after reboot, run: $SCRIPT_NAME doctor"
    fi

    _sep

    # Also verify the blacklist file is what we expect
    if [[ -f "$BLACKLIST_CONF" ]]; then
        local missing=()
        for mod in nvidia nvidia_drm nvidia_modeset nvidia_uvm; do
            grep -q "install ${mod} /bin/false" "$BLACKLIST_CONF" || missing+=("$mod")
        done
        if [[ ${#missing[@]} -eq 0 ]]; then
            printf "  %s  %s contains all install-override lines.\n" \
                "$(_badge PASS)" "$BLACKLIST_CONF"
        else
            printf "  %s  Missing install-override for: %s\n" \
                "$(_badge FAIL)" "${missing[*]}"
        fi
    else
        printf "  %s  %s does not exist.\n" "$(_badge FAIL)" "$BLACKLIST_CONF"
    fi

    _sep
}

# ==========================================================
# verify_services -- check masking/unmasking took effect
# ==========================================================

verify_services() {
    local expected_state="$1"   # "masked" or "enabled"

    echo
    _hdr "Service State Check"
    _sep

    printf "  ${DIM}%-45s  %s${RST}\n" "SERVICE" "STATE"
    _sep

    for svc in "${SERVICES[@]}"; do
        local state
        state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-found")
        local badge

        if [[ "$expected_state" == "masked" ]]; then
            [[ "$state" == "masked" ]] && badge="$(_badge PASS)" || badge="$(_badge WARN)"
        else
            [[ "$state" == "disabled" || "$state" == "enabled" || "$state" == "static" ]] \
                && badge="$(_badge PASS)" || badge="$(_badge WARN)"
        fi

        printf "  %s  ${DIM}%-45s${RST}  %s\n" "$badge" "$svc" "$state"
    done

    _sep
}

# ==========================================================
# verify_prime -- check prime-select query matches expectation
# ==========================================================

verify_prime() {
    local expected="$1"
    local actual
    actual=$(prime-select query 2>/dev/null || echo "unknown")

    echo
    _hdr "PRIME Profile Check"
    _sep

    if [[ "$actual" == "$expected" ]]; then
        printf "  %s  prime-select query = %s\n" "$(_badge PASS)" "$actual"
    else
        printf "  %s  Expected '%s', got '%s'\n" "$(_badge FAIL)" "$expected" "$actual"
        _warn "PRIME switch may not have taken effect yet -- reboot and verify."
    fi

    _sep
}

# ==========================================================
# services
# ==========================================================

mask_services() {
    for s in "${SERVICES[@]}"; do
        sudo systemctl stop    "$s" 2>/dev/null || true
        sudo systemctl disable "$s" 2>/dev/null || true
        sudo systemctl mask    "$s" 2>/dev/null || true
    done
}

unmask_services() {
    for s in "${SERVICES[@]}"; do
        sudo systemctl unmask "$s" 2>/dev/null || true
    done
}

remove_psm_files() {
    sudo rm -f "$BLACKLIST_CONF"
    sudo rm -f "$UDEV_DISABLE_RULE"
    sudo rm -f "$LOWPOWER_SERVICE"
    sudo rm -f "$OFF_PM_SERVICE"
    sudo udevadm control --reload 2>/dev/null || true
    sudo systemctl daemon-reload  2>/dev/null || true
}

# ==========================================================
# status -- compact overview table
# ==========================================================

status() {
    require_cmd lspci

    echo
    _hdr "NVIDIA Power State Manager -- Status"
    _sep

    # --- GPU identity ---
    printf "  ${DIM}%-24s${RST} %s\n" "GPU BDF" "$GPU_BDF"
    printf "  ${DIM}%-24s${RST} %s\n" "Audio BDF" "$AUDIO_BDF"

    _sep

    # --- Power / PM ---
    local rs pc
    rs=$(runtime_status)
    pc=$(power_control)

    local rs_col="$RST"
    [[ "$rs" == "suspended" ]] && rs_col="$GRN"
    [[ "$rs" == "active"    ]] && rs_col="$YLW"

    local pc_col="$RST"
    [[ "$pc" == "auto" ]] && pc_col="$GRN"
    [[ "$pc" == "on"   ]] && pc_col="$YLW"

    _kv "runtime_status"    "$rs" "$rs_col"
    _kv "power/control"     "$pc" "$pc_col"

    _sep

    # --- PRIME / renderer ---
    local prime_profile
    prime_profile=$(prime-select query 2>/dev/null || echo "unknown")
    _kv "PRIME profile"     "$prime_profile"
    _kv "GL renderer"       "$(renderer)"

    _sep

    # --- Modules ---
    local mods
    mods=$(lsmod | awk 'NR>1 && /nvidia|nouveau|amdgpu/{print $1}' | tr '\n' '  ' || true)
    [[ -z "$mods" ]] && mods="none"
    _kv "loaded modules"    "$mods"

    # --- Driver binding ---
    local driver_in_use
    driver_in_use=$(lspci -k -s "$GPU_BDF" 2>/dev/null \
        | grep "Kernel driver in use" \
        | awk -F': ' '{print $2}' || echo "none")
    _kv "driver bound"      "${driver_in_use:-none}"

    power_snapshot

    # --- Blacklist / udev files owned by this script ---
    echo
    _hdr "Persistent Config Files (psm-owned)"
    _sep
    for f in "$BLACKLIST_CONF" "$UDEV_DISABLE_RULE" "$LOWPOWER_SERVICE" "$OFF_PM_SERVICE"; do
        if [[ -f "$f" ]]; then
            printf "  ${GRN}  present${RST}  ${DIM}%s${RST}\n" "$f"
        else
            printf "  ${DIM}  absent ${RST}  ${DIM}%s${RST}\n" "$f"
        fi
    done
    _sep
}

# ==========================================================
# diagnose -- verbose debugging dump
# ==========================================================

diagnose() {
    echo
    _hdr "NVIDIA Diagnostics -- Verbose"
    _sep

    _hdr "Kernel"
    uname -a

    _hdr "PCI Topology"
    lspci | grep -Ei "vga|3d|display|nvidia|amd"

    _hdr "Detailed NVIDIA PCI"
    sudo lspci -vv -s "$GPU_BDF" 2>/dev/null || true

    _hdr "Runtime PM"
    _kv "runtime_status" "$(runtime_status)"
    _kv "power/control"  "$(power_control)"

    _hdr "Session"
    _kv "XDG_SESSION_TYPE" "${XDG_SESSION_TYPE:-unknown}"
    _kv "DISPLAY"          "${DISPLAY:-unset}"
    _kv "WAYLAND_DISPLAY"  "${WAYLAND_DISPLAY:-unset}"

    _hdr "GL Renderer"
    renderer

    _hdr "Kernel Logs (last 60 nvidia/pci/acpi lines)"
    sudo dmesg | grep -iE "nvidia|nouveau|amdgpu|acpi|pci" | tail -n 60 || true

    _hdr "Interrupt Activity"
    grep -Ei "nvidia|amdgpu|nvme|xhci" /proc/interrupts || true

    _hdr "Processes on /dev/dri/*"
    sudo fuser -v /dev/dri/* 2>/dev/null || echo "none / fuser unavailable"

    power_snapshot
}

# ==========================================================
# doctor -- PASS/WARN/FAIL checklist
# ==========================================================

doctor() {
    echo
    _hdr "NVIDIA Configuration Doctor"
    _sep

    local overall_ok=true

    check() {
        # check "label" "badge" "detail"
        printf "  %s  ${DIM}%-30s${RST}  %s\n" "$(_badge "$2")" "$1" "$3"
        [[ "$2" == "FAIL" ]] && overall_ok=false
    }

    # PRIME profile
    local prime_profile
    prime_profile=$(prime-select query 2>/dev/null || echo "unknown")
    case "$prime_profile" in
        nvidia)     check "PRIME profile" WARN "nvidia -- dGPU drives desktop" ;;
        on-demand)  check "PRIME profile" PASS "on-demand" ;;
        amd|intel)  check "PRIME profile" PASS "$prime_profile -- iGPU only" ;;
        *)          check "PRIME profile" WARN "$prime_profile" ;;
    esac

    # Runtime PM
    local rs pc
    rs=$(runtime_status); pc=$(power_control)
    [[ "$rs" == "suspended" ]] \
        && check "runtime_status" PASS "suspended" \
        || check "runtime_status" WARN "$rs"
    [[ "$pc" == "auto" ]] \
        && check "power/control" PASS "auto" \
        || check "power/control" WARN "$pc"

    # Modules
    local loaded_mods
    loaded_mods=$(lsmod | awk '/nvidia/{print $1}' | tr '\n' ' ' || true)
    if [[ -z "${loaded_mods// }" ]]; then
        check "nvidia modules" PASS "none loaded"
    else
        check "nvidia modules" WARN "loaded: $loaded_mods"
    fi

    # Nouveau
    lsmod | grep -q nouveau \
        && check "nouveau module" WARN "loaded -- may conflict" \
        || check "nouveau module" PASS "not loaded"

    # Blacklist file
    if [[ -f "$BLACKLIST_CONF" ]]; then
        # Check for strong install-override lines (not just blacklist)
        local missing_overrides=()
        for mod in nvidia nvidia_drm nvidia_modeset nvidia_uvm; do
            grep -q "install ${mod} /bin/false" "$BLACKLIST_CONF" \
                || missing_overrides+=("$mod")
        done
        if [[ ${#missing_overrides[@]} -eq 0 ]]; then
            check "blacklist config" PASS "$BLACKLIST_CONF (with install-overrides)"
        else
            check "blacklist config" WARN "missing install-override for: ${missing_overrides[*]}"
        fi
    else
        check "blacklist config" PASS "not present (normal if not in OFF mode)"
    fi

    # Stale udev NVIDIA rules in /etc/udev/rules.d
    local stale_udev
    stale_udev=$(find /etc/udev/rules.d -iname '*nvidia*' \
        ! -name "$(basename "$UDEV_DISABLE_RULE")" 2>/dev/null | tr '\n' ' ' || true)
    if [[ -z "${stale_udev// }" ]]; then
        check "stale udev rules" PASS "none found"
    else
        check "stale udev rules" WARN "$stale_udev"
    fi

    # /lib/udev/rules.d nvidia rules (from nvidia-prime package)
    local lib_udev
    lib_udev=$(find /lib/udev/rules.d -iname '*nvidia*' 2>/dev/null | tr '\n' ' ' || true)
    if [[ -n "${lib_udev// }" ]]; then
        check "lib udev rules" WARN "present (nvidia-prime pkg): $lib_udev"
    else
        check "lib udev rules" PASS "none"
    fi

    # Xorg conf referencing nvidia
    local xorg_nvidia
    xorg_nvidia=$(grep -rl nvidia /etc/X11/xorg.conf.d/ 2>/dev/null | tr '\n' ' ' || true)
    [[ -z "${xorg_nvidia// }" ]] \
        && check "xorg.conf.d nvidia refs" PASS "none" \
        || check "xorg.conf.d nvidia refs" WARN "$xorg_nvidia"

    # initramfs contamination
    local initrd_nvidia
    initrd_nvidia=$(lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null \
        | grep -i nvidia | wc -l || echo 0)
    if [[ "$initrd_nvidia" -eq 0 ]]; then
        check "initramfs nvidia entries" PASS "0 entries"
    else
        check "initramfs nvidia entries" WARN "$initrd_nvidia entries -- run verify_initramfs"
    fi

    # GRUB args
    local grub_nvidia
    grub_nvidia=$(grep -i nvidia /etc/default/grub 2>/dev/null || true)
    [[ -z "$grub_nvidia" ]] \
        && check "GRUB nvidia args" PASS "none" \
        || check "GRUB nvidia args" WARN "$grub_nvidia"

    # modules-load.d
    local modload_nvidia
    modload_nvidia=$(find /etc/modules-load.d -type f \
        | xargs grep -il nvidia 2>/dev/null | tr '\n' ' ' || true)
    [[ -z "${modload_nvidia// }" ]] \
        && check "modules-load.d" PASS "no nvidia entries" \
        || check "modules-load.d" WARN "$modload_nvidia"

    # Secure Boot
    local sb_state
    sb_state=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    if echo "$sb_state" | grep -qi "enabled"; then
        check "Secure Boot" WARN "enabled -- unsigned modules will fail silently"
    else
        check "Secure Boot" PASS "$sb_state"
    fi

    # DKMS
    if command -v dkms >/dev/null 2>&1; then
        local dkms_bad
        dkms_bad=$(dkms status 2>/dev/null | grep -iv "installed\|added" || true)
        [[ -z "$dkms_bad" ]] \
            && check "DKMS" PASS "all modules OK" \
            || check "DKMS" WARN "$dkms_bad"
    else
        check "DKMS" WARN "dkms not found"
    fi

    # Services
    _sep
    printf "  ${DIM}%-30s  %-10s  %s${RST}\n" "SERVICE" "STATE" ""
    _sep
    for svc in "${SERVICES[@]}"; do
        local state
        state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-found")
        printf "  ${DIM}%-30s  %-10s${RST}\n" "$svc" "$state"
    done

    _sep

    if $overall_ok; then
        _good "No FAIL items detected."
    else
        _bad  "One or more FAIL items require attention."
    fi

    echo
    _info "For full verbose output: $SCRIPT_NAME diagnose"
    _info "To recover:             $SCRIPT_NAME reset"
    _sep
}

# ==========================================================
# DISABLE mode  (runtime-only, no reboot)
# ==========================================================
# Quick non-invasive kill for the current session.
# Does NOT touch modprobe.d, initramfs, or PRIME -- nothing
# that requires a reboot or persists past the next boot.
# Use this when you're in a weird in-between state and just
# want the GPU off right now.

disable_mode() {
    echo
    _hdr "Mode: DISABLE (runtime-only)"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "Effect"       "Value"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "scope"        "current session only"
    printf "  ${DIM}%-20s${RST}  %s\n" "persistence"  "none -- reboot reverts"
    printf "  ${DIM}%-20s${RST}  %s\n" "touches"      "driver bind, services, sysfs PM"
    printf "  ${DIM}%-20s${RST}  %s\n" "does NOT"     "modprobe.d / initramfs / PRIME"
    printf "  ${DIM}%-20s${RST}  %s\n" "revert with"  "$SCRIPT_NAME reset  (or just reboot)"
    _sep

    confirm_action "Apply DISABLE mode?" || exit 1

    # 1. Stop and mask services for this session
    run "Stop and mask NVIDIA services" \
        bash -c "
            for s in ${SERVICES[*]}; do
                sudo systemctl stop   \"\$s\" 2>/dev/null || true
                sudo systemctl mask   \"\$s\" 2>/dev/null || true
            done
        "

    # 2. Unbind driver if currently bound -- must happen before PM writes
    local driver_now
    driver_now=$(lspci -k -s "$GPU_BDF" 2>/dev/null \
        | grep "Kernel driver in use" | awk -F': ' '{print $2}' || true)

    if [[ -n "$driver_now" && "$driver_now" != "none" ]]; then
        run "Unbind driver ($driver_now)" \
            bash -c "echo '$GPU_BDF' | sudo tee '$(gpu_sysfs)/driver/unbind' >/dev/null || true"
        sleep 1
    else
        _info "Driver not currently bound -- skipping unbind"
    fi

    # 3. Unload modules if still resident
    run "Unload NVIDIA kernel modules" \
        bash -c "
            for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
                sudo modprobe -r \"\$mod\" 2>/dev/null || true
            done
        "

    # 4. Sysfs PM writes -- enable runtime suspend on GPU and its bridge
    if [[ -e "$(gpu_power_control_path)" ]]; then
        run "Set GPU power/control = auto" \
            bash -c "echo auto | sudo tee '$(gpu_power_control_path)' >/dev/null"
        run "Set PCIe bridge power/control = auto" \
            bash -c "echo auto | sudo tee '/sys/bus/pci/devices/0000:00:01.1/power/control' >/dev/null || true"
        run "Set autosuspend_delay_ms = 0" \
            bash -c "echo 0 | sudo tee '$(gpu_sysfs)/power/autosuspend_delay_ms' >/dev/null || true"
    else
        _warn "GPU sysfs power path not present -- PM writes skipped"
    fi

    echo
    _good "DISABLE mode applied."
    echo
    _info "Verify:"
    _dim  "  cat /sys/bus/pci/devices/$GPU_BDF/power/runtime_status"
    _dim  "  lsmod | grep nvidia"
    echo
    _warn "This does not survive reboot. Run 'off' for persistent disable."
}

# ==========================================================
# OFF mode
# ==========================================================

off_mode() {
    echo
    _hdr "Mode: OFF"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "Effect"         "Value"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "desktop GPU"    "iGPU (amd/intel)"
    printf "  ${DIM}%-20s${RST}  %s\n" "NVIDIA modules" "blacklisted + install-overridden"
    printf "  ${DIM}%-20s${RST}  %s\n" "NVIDIA services" "masked"
    printf "  ${DIM}%-20s${RST}  %s\n" "runtime PM"     "auto"
    printf "  ${DIM}%-20s${RST}  %s\n" "persistence"    "yes -- survives reboot"
    printf "  ${DIM}%-20s${RST}  %s\n" "revert with"    "$SCRIPT_NAME reset"
    _sep

    confirm_action "Apply OFF mode?" || exit 1

    # 1. Nuke any stale psm-owned files first
    run "Remove stale psm rules/configs" \
        bash -c "
            sudo rm -f '$BLACKLIST_CONF' '$UDEV_DISABLE_RULE' '$LOWPOWER_SERVICE' '$OFF_PM_SERVICE'
            sudo udevadm control --reload 2>/dev/null || true
            sudo systemctl daemon-reload  2>/dev/null || true
        "

    # 2. PRIME -> iGPU
    run "Switch PRIME profile to iGPU" \
        sudo prime-select intel

    # 3. Mask NVIDIA services
    run "Mask NVIDIA services" \
        bash -c "
            for s in ${SERVICES[*]}; do
                sudo systemctl stop    \"\$s\" 2>/dev/null || true
                sudo systemctl disable \"\$s\" 2>/dev/null || true
                sudo systemctl mask    \"\$s\" 2>/dev/null || true
            done
        "

    # 4. Write blacklist with install-override (stronger than plain blacklist)
    #    'install nvidia /bin/false' prevents even explicit modprobe nvidia
    run "Write blacklist config (with install-overrides)" \
        bash -c "true"   # placeholder -- actual write below (write_verified reads stdin)

    write_verified "$BLACKLIST_CONF" <<'EOF'
# nvidia-psm: OFF mode
# 'install X /bin/false' is stronger than 'blacklist X':
# it blocks explicit modprobe calls too, not just automatic loading.
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm

install nvidia /bin/false
install nvidia_drm /bin/false
install nvidia_modeset /bin/false
install nvidia_uvm /bin/false
EOF

    # 5. Attempt immediate unbind if driver is bound right now.
    #    Must happen BEFORE writing power/control=auto -- if the driver
    #    is still bound it will reset power/control back to 'on' immediately.
    local driver_now
    driver_now=$(lspci -k -s "$GPU_BDF" 2>/dev/null \
        | grep "Kernel driver in use" | awk -F': ' '{print $2}' || true)

    if [[ -n "$driver_now" && "$driver_now" != "none" ]]; then
        run "Attempt immediate driver unbind ($driver_now)" \
            bash -c "echo '$GPU_BDF' | sudo tee '$(gpu_sysfs)/driver/unbind' >/dev/null || true"
        sleep 1
    else
        _info "Driver not currently bound -- skipping unbind"
    fi

    # 6. Enable runtime PM now that driver is unbound
    if [[ -e "$(gpu_power_control_path)" ]]; then
        run "Enable runtime PM on GPU (power/control = auto)" \
            bash -c "echo auto | sudo tee '$(gpu_power_control_path)' >/dev/null"
        run "Enable runtime PM on PCIe bridge (power/control = auto)" \
            bash -c "echo auto | sudo tee '/sys/bus/pci/devices/0000:00:01.1/power/control' >/dev/null || true"
        run "Set autosuspend delay to 0ms" \
            bash -c "echo 0 | sudo tee '$(gpu_sysfs)/power/autosuspend_delay_ms' >/dev/null || true"
    else
        _warn "GPU power control sysfs path not present -- skipping"
    fi

    # 7. Write a boot-time service to re-apply PM settings after every reboot.
    #    Needed because sysfs writes above don't survive reboot, and on this
    #    machine ACPI PEP is broken so the kernel won't set power/control=auto
    #    itself.  Service runs late (after graphical.target) to ensure PCIe
    #    devices are enumerated.
    run "Write D3hot PM persistence service" \
        bash -c "true"   # placeholder -- actual write below

    write_verified "$OFF_PM_SERVICE" <<EOF
# nvidia-psm: OFF mode -- force GPU toward D3hot on every boot
# Required because ACPI PEP._DSM is broken on this firmware (HP Omen F.32),
# preventing the kernel from autonomously gating dGPU power.
[Unit]
Description=NVIDIA dGPU D3hot power gate (nvidia-psm off)
After=graphical.target
ConditionPathExists=/sys/bus/pci/devices/$GPU_BDF/power/control

[Service]
Type=oneshot
RemainAfterExit=yes
# Bridge: allow it to power-gate when endpoint is idle
ExecStart=/bin/sh -c 'echo auto > /sys/bus/pci/devices/0000:00:01.1/power/control || true'
# GPU: allow runtime suspend, fire immediately
ExecStart=/bin/sh -c 'echo 0    > /sys/bus/pci/devices/$GPU_BDF/power/autosuspend_delay_ms || true'
ExecStart=/bin/sh -c 'echo auto > /sys/bus/pci/devices/$GPU_BDF/power/control || true'

[Install]
WantedBy=graphical.target
EOF

    run "Enable D3hot PM service" \
        bash -c "sudo systemctl daemon-reload && sudo systemctl enable nvidia-off-pm.service"

    # 8. Rebuild initramfs (embeds the blacklist)
    run "Rebuild initramfs (embeds blacklist)" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    # --- Sanity checks ---
    verify_initramfs
    verify_prime "intel"
    verify_services "masked"

    echo
    _good "OFF mode configured. Reboot to fully apply."
}

# ==========================================================
# LOWPOWER mode
# ==========================================================

lowpower_mode() {
    echo
    _hdr "Mode: LOWPOWER"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "Effect"          "Value"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "desktop GPU"     "iGPU (on-demand)"
    printf "  ${DIM}%-20s${RST}  %s\n" "CUDA"            "usable"
    printf "  ${DIM}%-20s${RST}  %s\n" "power cap"       "45 W (persistent via systemd)"
    printf "  ${DIM}%-20s${RST}  %s\n" "NVIDIA services" "unmasked"
    printf "  ${DIM}%-20s${RST}  %s\n" "persistence"     "yes -- survives reboot"
    printf "  ${DIM}%-20s${RST}  %s\n" "revert with"     "$SCRIPT_NAME reset"
    _sep

    confirm_action "Apply LOWPOWER mode?" || exit 1

    run "Remove stale psm rules/configs" \
        bash -c "
            sudo rm -f '$BLACKLIST_CONF' '$UDEV_DISABLE_RULE'
            sudo udevadm control --reload 2>/dev/null || true
        "

    run "Switch PRIME to on-demand" \
        sudo prime-select on-demand

    run "Unmask NVIDIA services" \
        bash -c "
            for s in ${SERVICES[*]}; do
                sudo systemctl unmask \"\$s\" 2>/dev/null || true
            done
        "

    run "Rebuild initramfs" \
        sudo update-initramfs -u

    # Load driver now so we can cap power in this session
    run "Load NVIDIA module (current session)" \
        bash -c "sudo modprobe nvidia || true"

    sleep 2

    # Apply power cap now
    run "Apply 45W power cap (current session)" \
        bash -c "sudo nvidia-smi -pl 45 || true"

    # Install a systemd service to re-apply cap after every boot
    run "Write persistent power cap systemd service" \
        bash -c "true"

    write_verified "$LOWPOWER_SERVICE" <<'EOF'
# nvidia-psm: LOWPOWER mode -- persistent power cap
[Unit]
Description=NVIDIA power cap (nvidia-psm lowpower)
After=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-smi -pl 45
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    run "Enable power cap service" \
        bash -c "sudo systemctl daemon-reload && sudo systemctl enable nvidia-power-cap.service"

    REBOOT_REQUIRED=true

    verify_prime "on-demand"
    verify_services "enabled"

    echo
    _good "LOWPOWER mode configured. Reboot to fully apply."
    _info "Power cap will be re-applied on every boot via nvidia-power-cap.service"
}

# ==========================================================
# FULL mode
# ==========================================================

full_mode() {
    echo
    _hdr "Mode: FULL"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "Effect"          "Value"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "desktop GPU"     "NVIDIA (prime nvidia)"
    printf "  ${DIM}%-20s${RST}  %s\n" "runtime PM"      "disabled (power/control=on)"
    printf "  ${DIM}%-20s${RST}  %s\n" "NVIDIA services" "unmasked"
    printf "  ${DIM}%-20s${RST}  %s\n" "persistence"     "yes -- survives reboot"
    printf "  ${DIM}%-20s${RST}  %s\n" "revert with"     "$SCRIPT_NAME reset"
    _sep

    confirm_action "Apply FULL mode?" || exit 1

    run "Remove stale psm rules/configs" \
        bash -c "
            sudo rm -f '$BLACKLIST_CONF' '$UDEV_DISABLE_RULE' '$LOWPOWER_SERVICE' '$OFF_PM_SERVICE'
            sudo udevadm control --reload 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true
        "

    run "Switch PRIME to nvidia" \
        sudo prime-select nvidia

    run "Unmask NVIDIA services" \
        bash -c "
            for s in ${SERVICES[*]}; do
                sudo systemctl unmask \"\$s\" 2>/dev/null || true
            done
        "

    # Disable runtime PM so GPU doesn't suspend during rendering
    if [[ -e "$(gpu_power_control_path)" ]]; then
        run "Disable runtime PM (power/control = on)" \
            bash -c "echo on | sudo tee '$(gpu_power_control_path)' >/dev/null"
    fi

    run "Rebuild initramfs" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    verify_prime "nvidia"
    verify_services "enabled"

    echo
    _good "FULL mode configured. Reboot to fully apply."
}

# ==========================================================
# reset
# ==========================================================

reset_mode() {
    echo
    _hdr "Mode: RESET"
    _sep
    printf "  ${DIM}%-20s${RST}  %s\n" "Removes"  "blacklist, udev rules, power cap service"
    printf "  ${DIM}%-20s${RST}  %s\n" "PRIME"    "-> on-demand"
    printf "  ${DIM}%-20s${RST}  %s\n" "Services" "unmasked"
    printf "  ${DIM}%-20s${RST}  %s\n" "Safety"   "non-destructive -- standard Ubuntu defaults"
    _sep

    confirm_action "Proceed with reset?" || exit 1

    run "Remove psm-owned config files" \
        bash -c "
            sudo rm -f '$BLACKLIST_CONF' '$UDEV_DISABLE_RULE' '$LOWPOWER_SERVICE' '$OFF_PM_SERVICE'
            sudo udevadm control --reload  2>/dev/null || true
            sudo systemctl daemon-reload   2>/dev/null || true
        "

    run "Unmask NVIDIA services" \
        bash -c "
            for s in ${SERVICES[*]}; do
                sudo systemctl unmask \"\$s\" 2>/dev/null || true
            done
        "

    run "Switch PRIME to on-demand" \
        sudo prime-select on-demand

    run "Rebuild initramfs" \
        sudo update-initramfs -u

    REBOOT_REQUIRED=true

    verify_prime "on-demand"
    verify_services "enabled"
    verify_initramfs

    echo
    _good "Reset complete. Reboot to fully apply."
    echo
    _warn "If GPU still misbehaves after reboot, inspect manually:"
    _dim  "  find /etc/modprobe.d /lib/modprobe.d -iname '*nvidia*'"
    _dim  "  find /etc/udev/rules.d -iname '*nvidia*'"
    _dim  "  find /lib/udev/rules.d -iname '*nvidia*'"
    _dim  "  grep -i nvidia /etc/default/grub"
    _dim  "  lsinitramfs /boot/initrd.img-\$(uname -r) | grep nvidia"
}

# ==========================================================
# driver update
# ==========================================================

update_drivers() {
    echo
    _hdr "Driver Update"
    _sep

    confirm_action "Install Ubuntu recommended NVIDIA drivers?" || exit 1

    run "Refresh package lists" \
        sudo apt update

    echo
    _info "Available drivers:"
    ubuntu-drivers devices 2>/dev/null || true
    echo

    echo -ne "  Install recommended drivers? [y/N]: "
    local ans; read -r ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        run "Install recommended drivers" \
            sudo ubuntu-drivers autoinstall

        run "Rebuild initramfs" \
            sudo update-initramfs -u

        REBOOT_REQUIRED=true
        _good "Driver update complete."
    else
        _warn "Installation skipped."
    fi
}

# ==========================================================
# usage
# ==========================================================

usage() {
    printf "%b" "\n"
    printf "%b" "${BLD}${CYN}nvidia-psm${RST} -- NVIDIA Power State Manager\n"
    printf "%b" "\n"
    printf "%b" "${BLD}USAGE${RST}\n"
    printf "%b" "    $SCRIPT_NAME [flags] <command>\n"
    printf "%b" "\n"
    printf "%b" "${BLD}FLAGS${RST}\n"
    printf "%b" "    -i, --interactive   Confirm each step before running\n"
    printf "%b" "\n"
    printf "%b" "${BLD}MODES${RST}\n"
    printf "%b" "    disable     Runtime-only GPU kill (no reboot, no persistence)\n"
    printf "%b" "    off         Persistent disable (blacklist + service mask, reboot required)\n"
    printf "%b" "    lowpower    iGPU desktop, CUDA usable, 45W cap persisted via systemd\n"
    printf "%b" "    full        Full NVIDIA, desktop on dGPU, runtime PM disabled\n"
    printf "%b" "    reset       Restore sane Ubuntu defaults (safe recovery)\n"
    printf "%b" "\n"
    printf "%b" "${BLD}DIAGNOSTICS${RST}\n"
    printf "%b" "    status      Compact overview table\n"
    printf "%b" "    diagnose    Verbose dump (dmesg, interrupts, turbostat)\n"
    printf "%b" "    doctor      PASS/WARN/FAIL checklist of all persistent config\n"
    printf "%b" "\n"
    printf "%b" "${BLD}DRIVER${RST}\n"
    printf "%b" "    update      Install Ubuntu recommended NVIDIA driver\n"
    printf "%b" "\n"
    printf "%b" "${BLD}NOTES${RST}\n"
    printf "%b" "    All mode changes require a reboot to fully apply.\n"
    printf "%b" "    Revert any mode with: $SCRIPT_NAME reset\n"
    printf "%b" "    If things break:     $SCRIPT_NAME doctor  ->  $SCRIPT_NAME reset  ->  reboot\n"
    printf "%b" "\n"
}

# ==========================================================
# main
# ==========================================================

main() {
    # Parse flags before command
    while [[ "${1:-}" =~ ^- ]]; do
        case "$1" in
            -i|--interactive)
                INTERACTIVE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                _bad "Unknown flag: $1"
                usage
                exit 1
                ;;
        esac
    done

    local cmd="${1:-}"

    case "$cmd" in
        -h|--help|help|"")
            usage
            exit 0
            ;;
    esac

    require_cmd lspci

    if ! gpu_present; then
        _bad "No NVIDIA GPU detected via lspci"
        exit 1
    fi

    detect_gpu_bdf
    detect_audio_bdf

    # Acquire sudo credentials once upfront so subsequent sudo calls
    # don't prompt mid-execution. Skipped in interactive mode since
    # the user is stepping through each command anyway.
    if ! $INTERACTIVE; then
        echo
        _info "Requesting sudo credentials (once for this session)"
        sudo -v || { _bad "sudo authentication failed"; exit 1; }
    fi

    case "$cmd" in
        disable)   disable_mode  ;;
        off)       off_mode      ;;
        lowpower)  lowpower_mode ;;
        full)      full_mode     ;;
        reset)     reset_mode    ;;
        status)    status        ;;
        diagnose)  diagnose      ;;
        doctor)    doctor        ;;
        update)    update_drivers ;;
        *)
            _bad "Unknown command: $cmd"
            usage
            exit 1
            ;;
    esac

    echo

    if $REBOOT_REQUIRED; then
        echo
        _sep
        _warn "Reboot required for changes to fully take effect."
        _sep
    fi
}

main "$@"