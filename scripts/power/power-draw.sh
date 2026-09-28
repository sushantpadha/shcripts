#!/bin/bash
# Snapshot of what is using power: battery draw, CPU, temps, NVIDIA state, GPU users
# Read-only. Run with sudo to also get CPU package watts and every process holding the GPU.
# Healthy idle on this laptop: 5-12 W on battery, NVIDIA suspended, Tctl 40-60 C.
set -uo pipefail

G="\033[1;32m" Y="\033[1;33m" R="\033[1;31m" C="\033[1;36m" D="\033[2m" B="\033[1m" N="\033[0m"
hdr()  { echo -e "\n${B}${C}$*${N}"; }
ok()   { echo -e "  ${G}+${N} $*"; }
warn() { echo -e "  ${Y}!${N} $*"; }
bad()  { echo -e "  ${R}x${N} $*"; }
hint() { echo -e "    ${D}$*${N}"; }

battery() {
    hdr "Battery draw"
    local bat; bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)
    [ -n "$bat" ] || { warn "no battery found"; return; }
    local status; status=$(cat "$bat/status")
    if [ "$status" != Discharging ]; then
        warn "$status: unplug the charger for a real reading"
        return
    fi
    local w
    if [ -r "$bat/power_now" ]; then
        w=$(( $(cat "$bat/power_now") / 1000000 ))
    else
        w=$(( $(cat "$bat/current_now") * $(cat "$bat/voltage_now") / 1000000000000 ))
    fi
    if   [ "$w" -le 12 ]; then ok  "${w} W (good idle)"
    elif [ "$w" -le 25 ]; then warn "${w} W (high if idle)"
    else                       bad "${w} W (something is busy)"; fi
}

cpu() {
    hdr "CPU"
    echo -e "  profile: $(powerprofilesctl get 2>/dev/null || echo ?)   boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo ?)"
    read -r avg max < <(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq |
        awk '{s+=$1; if ($1>m) m=$1} END {printf "%d %d", s/NR/1000, m/1000}')
    if [ "$avg" -lt 2000 ]; then ok "clocks avg ${avg} MHz, max ${max} MHz"
    else warn "clocks avg ${avg} MHz, max ${max} MHz (high for idle)"; fi

    local t; t=$(sensors 2>/dev/null | awk '/^Tctl:/ {gsub(/[+°C]/, "", $2); print int($2)}')
    if   [ -z "$t" ];     then warn "Tctl unknown (install lm-sensors)"
    elif [ "$t" -le 60 ]; then ok "Tctl ${t} C"
    elif [ "$t" -le 80 ]; then warn "Tctl ${t} C (warm)"
    else                       bad "Tctl ${t} C (hot)"; fi
    sensors 2>/dev/null | awk '/^fan[0-9]+:/ {printf "    %s %s RPM\n", $1, $2}'

    local rapl=/sys/class/powercap/intel-rapl:0/energy_uj
    if [ -r "$rapl" ]; then
        local e1 e2; e1=$(cat "$rapl"); sleep 1; e2=$(cat "$rapl")
        echo -e "  package: $(( (e2 - e1) / 1000000 )) W"
    else
        hint "package watts: run with sudo"
    fi

    echo -e "  ${D}top processes (last second):${N}"
    top -bn2 -d1 -w 512 -o %CPU | awk '/^top -/ {n++} n == 2 && $1 ~ /^[0-9]+$/ {printf "    %5s%%  %s\n", $9, $12}' | head -5
}

nvidia() {
    hdr "NVIDIA GPU"
    local dev
    for dev in /sys/bus/pci/devices/*; do
        [ "$(cat "$dev/vendor")" = 0x10de ] || continue
        [[ "$(cat "$dev/class")" == 0x03* ]] || continue
        local bdf rs ctl drv
        bdf=$(basename "$dev")
        rs=$(cat "$dev/power/runtime_status")
        ctl=$(cat "$dev/power/control")
        drv=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)
        echo -e "  $bdf  driver: ${drv:-none}  control: $ctl  $(cat "$dev/power_state" 2>/dev/null)"
        if [ "$rs" = suspended ]; then
            ok "suspended"
        else
            bad "$rs (awake, costs several W)"
            [ "$ctl" = auto ] || hint "runtime PM off. Try: echo auto | sudo tee $dev/power/control"
            echo -e "  ${D}processes holding it:${N}"
            local nodes=(/dev/nvidia* /dev/dri/by-path/pci-"$bdf"-*)
            fuser -v "${nodes[@]}" 2>&1 | awk 'NR>1 && NF {print "    " $0}' | sort -u
            [ "$EUID" -eq 0 ] || hint "run with sudo to see other users' processes"
        fi
    done
    hint "don't use nvidia-smi to check: it wakes the GPU"
}

session() {
    hdr "Session"
    echo "  ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}   ASPM policy: $(grep -o '\[[a-z]*\]' /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo ?)"
}

while true; do
    clear
    echo -e "${B}power draw${N}  ${D}$(date '+%F %T')${N}"
    battery; cpu; nvidia; session
    echo -e "\n${D}deeper: sudo powertop | sudo turbostat --Summary | htop${N}"
    read -rp $'\nEnter = refresh, q = quit: ' k
    [ "$k" = q ] && break
done
