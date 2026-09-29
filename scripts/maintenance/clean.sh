#!/bin/bash
# Clean generated files and safe caches (shcripts, user, system) and explore disk usage. Asks before every step.
# Deletes only what it lists first. Never touches .env, .venv, your projects, or models/data in ~/.cache.
set -euo pipefail

ROOT="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "$ROOT/launcher/launcher.py" ] || { echo "not a shcripts repo: $ROOT"; exit 1; }

RED="\033[1;31m" GRN="\033[1;32m" YLW="\033[1;33m" CYN="\033[1;36m" DIM="\033[2m" BLD="\033[1m" RST="\033[0m"
shopt -s nullglob
deleted=0
MODE=ask    # set per section: ask = confirm each group, all = delete every group in the section

sz() { du -shc "$@" 2>/dev/null | tail -1 | cut -f1; }
avail() { df -B1 --output=avail / | tail -1 | tr -d ' '; }

# ask <label> <y|n default> <note> <size>: 0 = yes
ask() {
    local a
    echo -e "\n${CYN}$1${RST}  ($4)  ${DIM}$3${RST}"
    if [ "$MODE" = all ]; then a=y; echo -e "  ${DIM}delete all: yes${RST}"
    else read -rp "  Delete? [$([ "$2" = y ] && echo Y/n || echo y/N)] " a || a=""; a=${a:-$2}; fi
    if [[ "$a" =~ ^[Yy]$ ]]; then deleted=$((deleted + 1)); return 0; fi
    echo -e "  ${DIM}kept${RST}"
    return 1
}

# clean <label> <default> <note> <path>...: list what exists, ask, rm -rf
clean() {
    local label=$1 def=$2 note=$3 found=() p
    shift 3
    for p in "$@"; do [ -e "$p" ] && found+=("$p"); done
    if [ ${#found[@]} -eq 0 ]; then echo -e "${DIM}- $label: nothing to clean${RST}"; return; fi
    if ask "$label" "$def" "$note" "$(sz "${found[@]}")"; then
        printf '  %s\n' "${found[@]:0:4}"
        [ ${#found[@]} -le 4 ] || echo "  ... and $(( ${#found[@]} - 4 )) more"
        rm -rf -- "${found[@]}"
        echo -e "  ${GRN}deleted${RST}"
    fi
}

# run <label> <default> <note> <size> -- <command>...: ask, then run the command (shown first)
run() {
    local label=$1 def=$2 note=$3 size=$4
    shift 5
    if ask "$label" "$def" "$note" "$size"; then
        echo -e "  ${DIM}\$ $*${RST}"
        "$@" && echo -e "  ${GRN}done${RST}" || echo -e "  ${RED}failed, continuing${RST}"
    fi
}

# section <title> <groups that default to no>: sets MODE, returns 1 to skip the section
section() {
    local a
    echo -e "\n${BLD}== $1 ==${RST}"
    read -rp "  [a] delete all   [s] select each (default)   [n] skip: " a || a=n
    MODE=ask
    case "${a:-s}" in
        [Ss]) ;;
        [Aa])
            echo -e "  ${YLW}'all' also deletes the groups that normally default to no: $2${RST}"
            read -rp "  Really delete all? [y/N] " a || a=n
            if [[ "$a" =~ ^[Yy]$ ]]; then MODE=all; else echo -e "  ${DIM}ok, selecting each${RST}"; fi ;;
        *) return 1 ;;
    esac
}

explore() {
    local a p t
    echo -e "\n${BLD}== Disk usage ==${RST}"
    df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs
    read -rp "Explore what is using the space? [y/N] " a || a=n
    [[ "${a:-n}" =~ ^[Yy]$ ]] || return 0
    read -rp "Path [/]: " p || p=/
    p=${p:-/}
    echo "  1) ncdu    terminal, interactive (d deletes inside it, q quits)"
    echo "  2) baobab  GNOME Disk Usage Analyzer, GUI"
    echo "  3) du      the 25 biggest folders, 2 levels deep"
    echo -e "  ${DIM}One filesystem at a time (-x): run again for /mnt/data etc. As a normal user, root-owned folders are skipped.${RST}"
    read -rp "Pick [1]: " t || t=3
    case "${t:-1}" in
        1) command -v ncdu >/dev/null && ncdu -x "$p" || echo "ncdu missing: sudo apt install ncdu" ;;
        2) command -v baobab >/dev/null && setsid -f baobab "$p" >/dev/null 2>&1 || echo "baobab missing" ;;
        3) du -xh --max-depth=2 "$p" 2>/dev/null | sort -rh | head -25 ;;
    esac
}

echo -e "${CYN}shcripts clean${RST}  ($ROOT)"
echo "Every group is listed first and deleted only if you say yes."
free_before=$(avail)
explore

if section "shcripts files" "Memory log, Syncdrive history"; then
    mapfile -t pyc < <(find "$ROOT" -name __pycache__ -type d -not -path "$ROOT/.venv/*" -not -path "$ROOT/.git/*")
    clean "Run logs"         y "logs/<category>/, one file per launcher run" "$ROOT"/logs/*/
    clean "Run history"      y "last-3-runs record shown in the TUI" "$ROOT/.history.json"
    clean "Idle marker"      y "resets the 24 h idle reminder until you open the launcher again" "$ROOT/.lastopen"
    clean "Stale exit files" y "left in /tmp when a run was interrupted" /tmp/shcripts_*.exit
    clean "Python bytecode"  y "__pycache__ in this repo, rebuilt on the next run" "${pyc[@]}"
    clean "Memory log"       n "logs/memlog.txt; the tray starts a fresh one on its next snapshot" "$ROOT/logs/memlog.txt" "$ROOT/logs/memlog.txt.old"
    clean "Syncdrive history" n "~/.syncdrive: resets the 'last synced' times and old manifests" "$HOME/.syncdrive"
fi

if section "User caches (safe to delete, apps rebuild them)" "Trash, VS Code caches, C/C++ IntelliSense cache, Chrome cache, Spotify cache (close those apps first)"; then
    C=$HOME/.cache
    clean "Thumbnails"       y "regenerated when a folder is opened" "$C/thumbnails"
    clean "pip cache"        y "packages re-download on the next install" "$C/pip"
    clean "uv cache"         y "packages re-download on the next install" "$C/uv"
    clean "npm cache"        y "packages re-download on the next install" "$HOME/.npm/_cacache"
    clean "Go build cache"   y "rebuilt on the next go build" "$C/go-build"
    clean "Trash"            n "files you deleted in the file manager, gone for good" "$HOME"/.local/share/Trash/files/* "$HOME"/.local/share/Trash/info/*
    clean "VS Code caches"   n "close VS Code first; rebuilt on start" "$HOME/.config/Code/Cache" "$HOME/.config/Code/CachedData" "$HOME/.config/Code/CachedExtensionVSIXs" "$HOME/.config/Code/Code Cache" "$HOME/.config/Code/GPUCache"
    clean "C/C++ IntelliSense cache" n "close VS Code first; rebuilt when you open C/C++ code" "$C/vscode-cpptools"
    clean "Chrome cache"     n "close Chrome first; pages load slower once" "$C/google-chrome"
    clean "Spotify cache"    n "close Spotify first; songs re-download" "$C/spotify"
    echo -e "\n${DIM}Biggest folders in ~/.cache (not touched unless listed above; models and data can live here):${RST}"
    du -sh "$C"/* 2>/dev/null | sort -rh | head -8 | sed 's/^/  /'
fi

if section "System (needs sudo)" "Unused packages (apt still asks), Old system logs, Old snap revisions"; then
    if sudo -v; then
        run "APT package cache" y "downloaded .deb files" "$(sz /var/cache/apt/archives)" -- sudo apt-get clean
        pkgs=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv/{print $2}' | tr '\n' ' ')
        [ -z "$pkgs" ] || run "Unused packages" n "apt asks again before removing: ${pkgs:0:120}" "$(wc -w <<<"$pkgs") packages" -- sudo apt-get autoremove --purge
        [ -z "$(find /var/crash -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ] ||
            run "Crash reports" y "/var/crash" "$(sz /var/crash)" -- sudo find /var/crash -mindepth 1 -delete
        run "Old system logs" n "keeps 14 days; memlog-report reads kernel OOM kills from the journal" "$(sz /var/log/journal)" -- sudo journalctl --vacuum-time=14d
        old=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' || true)
        if [ -n "$old" ] && ask "Old snap revisions" n "disabled versions kept after snap updates" "$(wc -l <<<"$old") revisions"; then
            while read -r name rev; do sudo snap remove "$name" --revision="$rev"; done <<<"$old"
        fi
    else
        echo -e "${YLW}sudo not available, skipping${RST}"
    fi
fi

gained=$(( $(avail) - free_before ))
echo -e "\n${GRN}Done.${RST} $deleted group(s) cleaned. Free space on /: $(numfmt --to=iec "$(avail)")$([ "$gained" -gt 0 ] && echo " (+$(numfmt --to=iec "$gained"))")"
