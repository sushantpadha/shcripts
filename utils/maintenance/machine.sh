#!/bin/bash
# Machine check for scripts/maintenance/clean.sh. Source it, do not run it.
# The saved system info lives in .env (MAINTENANCE_MACHINE_*, gitignored), written by machine_save.
# Needs from clean.sh: colors (RED GRN YLW DIM BLD RST), ROOT.

MACHINE_FIELDS=(HOST MODEL OS KERNEL KERNEL_SUM ID_SUM CPU RAM_GB GPU DISKS)
clean_val() { tr -d '"$`\\'; }   # values are sourced by bash from .env: no quotes, $, backticks

machine_now() {   # current values into N_<FIELD>
    N_SAVED=$(date +%F)
    N_HOST=$(hostname | clean_val)
    N_MODEL=$( (cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown) | clean_val)
    N_OS=$(. /etc/os-release && echo "$PRETTY_NAME" | clean_val)
    N_KERNEL=$(uname -r)
    N_KERNEL_SUM=$(uname -srvm | sha256sum | cut -c1-12)
    N_ID_SUM=$(echo "shcripts-clean:$(cat /etc/machine-id)" | sha256sum | cut -c1-16)   # salted: not the raw machine id
    N_CPU=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo | sed -E 's/ w\/.*//; s/\((R|TM)\)//g' | clean_val)
    N_RAM_GB=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
    N_GPU=$(lspci 2>/dev/null | grep -Ei 'vga|3d' | sed -E 's/^[0-9a-f:.]+ [^:]*: //; s/ \(rev [0-9a-f]+\)//; s/Advanced Micro Devices, Inc\. \[AMD\/ATI\] /AMD /; s/NVIDIA Corporation [A-Z0-9]+ \[(.*)\]/NVIDIA \1/' | paste -sd'+' | sed 's/+/ + /g' | clean_val)
    N_DISKS=$(lsblk -dno NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk"{printf "%s %s, ", $1, $2}' | sed 's/, $//')
}

machine_save() {   # write today's values into .env, right after the "### maintenance ###" header
    local env="$ROOT/.env" tmp f v; tmp=$(mktemp)
    machine_now
    touch "$env"
    grep -v -e '^MAINTENANCE_MACHINE_' -e '^# saved system info' "$env" > "$tmp" || true
    {
        echo "# saved system info for clean.sh: written by --refresh-header, do not edit by hand"
        echo "MAINTENANCE_MACHINE_SAVED=\"$N_SAVED\""
        for f in "${MACHINE_FIELDS[@]}"; do v=N_$f; echo "MAINTENANCE_MACHINE_$f=\"${!v}\""; done
    } > "$tmp.blk"
    if grep -q '^### maintenance ###' "$tmp"; then
        awk -v blk="$tmp.blk" '{print} /^### maintenance ###/ {while ((getline l < blk) > 0) print l}' "$tmp" > "$tmp.new"
    else
        { cat "$tmp"; echo; echo "### maintenance ###"; cat "$tmp.blk"; } > "$tmp.new"
    fi
    cat "$tmp.new" > "$env"   # cat >, not mv: keeps the file's owner and permissions
    rm -f "$tmp" "$tmp.blk" "$tmp.new"
    echo -e "${GRN}System info saved${RST} to $env ($N_SAVED, $N_HOST, kernel $N_KERNEL)"
}

machine_check() {   # banner, then stop unless this is the machine the saved info describes
    local soft=0 f s n a
    machine_now
    echo -e "${BLD}${YLW}┌───────────────────────────────────────────────────────────────────────────────┐${RST}"
    echo -e "${BLD}${YLW}│  VERY USER-SPECIFIC: built for one machine and one person. Not a general tool. │${RST}"
    echo -e "${BLD}${YLW}└───────────────────────────────────────────────────────────────────────────────┘${RST}"
    if [ -z "${MAINTENANCE_MACHINE_HOST:-}" ]; then
        echo -e "${BLD}${RED}No system info saved in .env, so this script does not know if this is the right machine.${RST}"
        echo -e "${DIM}On the machine it is meant for, run it once with --refresh-header.${RST}"
        exit 1
    fi
    echo -e "${DIM}System info saved on ${MAINTENANCE_MACHINE_SAVED:-?}, compared with this machine now:${RST}"
    for f in "${MACHINE_FIELDS[@]}"; do
        s=MAINTENANCE_MACHINE_$f; n=N_$f
        if [ "${!s:-}" = "${!n}" ]; then printf '  %-10s %-56s %b\n' "$(tr 'A-Z_' 'a-z ' <<<"$f")" "${!n}" "${GRN}ok${RST}"
        else printf '  %-10s %-56s %b\n' "$(tr 'A-Z_' 'a-z ' <<<"$f")" "${!s:-}" "${YLW}now: ${!n}${RST}"; soft=1; fi
    done
    if [ "${MAINTENANCE_MACHINE_HOST:-}" != "$N_HOST" ] || [ "${MAINTENANCE_MACHINE_ID_SUM:-}" != "$N_ID_SUM" ]; then
        echo -e "\n${BLD}${RED}This is not the machine this script was written for. Stopping.${RST}"
        echo -e "${DIM}If it really is yours now (new install, new laptop), run it once with --refresh-header.${RST}"
        exit 1
    fi
    if [ "$soft" = 1 ]; then
        read -rp "Some values changed since ${MAINTENANCE_MACHINE_SAVED:-?}. Save the current ones now? [y/N] " a || a=n
        if [[ "$a" =~ ^[Yy]$ ]]; then machine_save; fi
    fi
    echo
}
