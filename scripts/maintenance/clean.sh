#!/bin/bash
# Clean generated files: run logs, run history, idle marker, memory log, syncdrive history (asks per group)
# Deletes only generated files. Never touches .env, .venv, scripts or your synced folders.
set -euo pipefail

ROOT="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "$ROOT/launcher/launcher.py" ] || { echo "not a shcripts repo: $ROOT"; exit 1; }

RED="\033[1;31m" GRN="\033[1;32m" CYN="\033[1;36m" DIM="\033[2m" RST="\033[0m"
shopt -s nullglob
freed=0

# clean <label> <y|n default> <note> <path>...  : show what exists, ask, delete
clean() {
    local label=$1 def=$2 note=$3 found=() p a
    shift 3
    for p in "$@"; do [ -e "$p" ] && found+=("$p"); done
    if [ ${#found[@]} -eq 0 ]; then echo -e "${DIM}- $label: nothing to clean${RST}"; return; fi

    echo -e "\n${CYN}$label${RST}  ($(du -shc "${found[@]}" | tail -1 | cut -f1))  ${DIM}$note${RST}"
    printf '  %s\n' "${found[@]:0:5}"
    [ ${#found[@]} -le 5 ] || echo "  ... and $(( ${#found[@]} - 5 )) more"

    read -rp "  Delete? [$([ "$def" = y ] && echo Y/n || echo y/N)] " a || a=""
    a=${a:-$def}
    if [[ "$a" =~ ^[Yy]$ ]]; then
        rm -rf -- "${found[@]}"
        echo -e "  ${GRN}deleted${RST}"
        freed=$((freed + 1))
    else
        echo -e "  ${DIM}kept${RST}"
    fi
}

echo -e "${CYN}shcripts clean${RST}  ($ROOT)"
echo "Each group is shown first and deleted only if you say yes."

clean "Run logs"          y "logs/<category>/, one file per launcher run" "$ROOT"/logs/*/
clean "Run history"       y "last-3-runs record shown in the TUI"         "$ROOT/.history.json"
clean "Idle marker"       y "resets the 24 h idle reminder until you open the launcher again" "$ROOT/.lastopen"
clean "Stale exit files"  y "left in /tmp when a run was interrupted"     /tmp/shcripts_*.exit
clean "Memory log"        n "logs/memlog.txt; the tray starts a fresh one on its next snapshot" "$ROOT/logs/memlog.txt" "$ROOT/logs/memlog.txt.old"
clean "Syncdrive history" n "~/.syncdrive: resets the 'last synced' times and old manifests" "$HOME/.syncdrive"

echo -e "\n${GRN}Done.${RST} $freed group(s) deleted."
