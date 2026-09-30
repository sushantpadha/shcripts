#!/bin/bash
# Clean generated files and safe caches (shcripts, user, system), review big folders, list installed software. Asks before every step.
#
# HOOK (for Claude or any editor): whenever this file or utils/maintenance/*.sh is edited, run
#     bash scripts/maintenance/clean.sh --refresh-header
# and say so in the commit. It re-saves this machine's system info (shown in the banner) into .env.
#
# Written for ONE machine and one person: it checks the saved system info and stops elsewhere.
# Deletes only what it lists first. Never touches .env, .venv, your projects, or models/data in ~/.cache.
set -euo pipefail

RED="\033[1;31m" GRN="\033[1;32m" YLW="\033[1;33m" CYN="\033[1;36m" DIM="\033[2m" BLD="\033[1m" RST="\033[0m"

# ── setup and machine check ───────────────────────────────────────────────────

ROOT="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "$ROOT/launcher/launcher.py" ] || { echo "not a shcripts repo: $ROOT"; exit 1; }
[ -f "$ROOT/.env" ] && { set -a; source "$ROOT/.env"; set +a; }   # MAINTENANCE_* settings and saved system info
source "$ROOT/utils/maintenance/machine.sh"
if [ "${1:-}" = "--refresh-header" ]; then machine_save; exit 0; fi
machine_check

JOURNAL_DAYS="${MAINTENANCE_JOURNAL_DAYS:-7}"
shopt -s nullglob
deleted=0

sz() { [ $# -gt 0 ] || { echo 0; return; }; du -shc "$@" 2>/dev/null | tail -1 | cut -f1; }
availf() { df -B1 --output=avail "$1" | tail -1 | tr -d ' '; }
source "$ROOT/utils/maintenance/analysis.sh"
source "$ROOT/utils/maintenance/software.sh"

# ── helpers ───────────────────────────────────────────────────────────────────

# ask <label> <y|n default> <note> <size>: 0 = yes. If INFO names a function, h prints its details.
ask() {
    local a
    echo -e "\n${CYN}$1${RST}  ($4)  ${DIM}$3${RST}"
    while :; do
        read -rp "  Delete? [$([ "$2" = y ] && echo Y/n || echo y/N)${INFO:+/h}] " a || a=""
        if [[ "$a" =~ ^[Hh]$ && -n "${INFO:-}" ]]; then "$INFO" || true; continue; fi
        a=${a:-$2}; break
    done
    if [[ "$a" =~ ^[Yy]$ ]]; then deleted=$((deleted + 1)); return 0; fi
    echo -e "  ${DIM}kept${RST}"
    return 1
}

# clean <label> <default> <note> <path>...: list what exists, ask, rm -rf. h lists the biggest items (or INFO=function for more).
clean() {
    local label=$1 def=$2 note=$3 found=() p
    local INFO=${INFO:-i_paths}
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

# section <title>: go through its groups? Every group still asks before deleting.
section() {
    local a
    echo -e "\n${BLD}== $1 ==${RST}"
    read -rp "  Go through this section? [Y/n] " a || a=n
    [[ "${a:-y}" =~ ^[Yy]$ ]]
}

explore() {
    local a p t
    read -rp "Explore what is using the space with ncdu / baobab / du? [y/N] " a || a=n
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

free_report() {   # free space on / and in home (home can be on another filesystem); "after" adds the change
    local r h; r=$(availf /); h=$(availf "$HOME")
    printf '  free on /: %s' "$(numfmt --to=iec "$r")"
    [ -z "${1:-}" ] || printf ' (%+d MB)' $(( (r - free_root) / 1048576 ))
    if [ "$(df --output=source / | tail -1)" != "$(df --output=source "$HOME" | tail -1)" ]; then
        printf '     free in home: %s' "$(numfmt --to=iec "$h")"
        [ -z "${1:-}" ] || printf ' (%+d MB)' $(( (h - free_home) / 1048576 ))
    fi
    echo
}

# ── start ─────────────────────────────────────────────────────────────────────

echo -e "${CYN}shcripts clean${RST}  ($ROOT)"
echo "Every group is listed first and deleted only if you say yes. At a delete prompt, h shows details."
free_root=$(availf /); free_home=$(availf "$HOME")
free_report

read -rp $'\nShow the analysis first (where is the space, what to review by hand)? [Y/n] ' a || a=n
if [[ "${a:-y}" =~ ^[Yy]$ ]]; then
    run_reports "Where is the space?" "${REPORTS_SPACE[@]}"
    run_reports "Manual pruning and review (this script never deletes these)" "${REPORTS_REVIEW[@]}"
    explore
fi

read -rp $'\nShow an overview of all installed software? [Y/n] ' a || a=n
if [[ "${a:-y}" =~ ^[Yy]$ ]]; then
    echo; FULL=0 software_overview || true   # || true: a failing ls/find in a report must not stop the script
    read -rp $'\n[Enter] continue  [h] full lists: ' a || a=""
    if [[ "$a" =~ ^[Hh]$ ]]; then echo; FULL=1 software_overview || true; fi
fi

# ── delete groups ─────────────────────────────────────────────────────────────

if section "shcripts files"; then
    mapfile -t pyc < <(find "$ROOT" -name __pycache__ -type d -not -path "$ROOT/.venv/*" -not -path "$ROOT/.git/*")
    clean "Run logs"          y "logs/<category>/, one file per launcher run" "$ROOT"/logs/*/
    clean "Run history"       y "last-3-runs record shown in the TUI" "$ROOT/.history.json"
    clean "Idle marker"       y "resets the 24 h idle reminder until you open the launcher again" "$ROOT/.lastopen"
    clean "Stale exit files"  y "left in /tmp when a run was interrupted" /tmp/shcripts_*.exit
    clean "Python bytecode"   y "__pycache__ in this repo, rebuilt on the next run" "${pyc[@]}"
    clean "Memory log"        n "logs/memlog.txt; the tray starts a fresh one on its next snapshot" "$ROOT/logs/memlog.txt" "$ROOT/logs/memlog.txt.old"
    clean "Syncdrive history" n "~/.syncdrive: resets the 'last synced' times and old manifests" "$HOME/.syncdrive"
fi

if section "User caches (safe to delete, apps rebuild them)"; then
    C=$HOME/.cache
    mapfile -t tmpfiles < <(old_tmp)
    trashfiles=(); while read -r d; do trashfiles+=("$d"/files/* "$d"/info/*); done < <(trash_dirs)
    clean "Thumbnails"       y "regenerated when a folder is opened" "$C/thumbnails"
    clean "pip cache"        y "packages re-download on the next install" "$C/pip"
    clean "uv cache"         y "packages re-download on the next install" "$C/uv"
    clean "npm cache"        y "packages re-download on the next install" "$HOME/.npm/_cacache"
    clean "Go build cache"   y "rebuilt on the next go build" "$C/go-build"
    INFO=i_snapcache clean "Snap app caches" y "~/snap/<app>/common/.cache (browsers, Discord, ...)" "$HOME"/snap/*/common/.cache
    INFO=i_devcache clean "Haskell and Rust download caches" y "ghcup, cabal and cargo re-download when needed" "$HOME/.ghcup/cache" "$HOME/.cabal/packages" "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src"
    if command -v go >/dev/null && [ -d "$HOME/go/pkg/mod" ]; then
        INFO=i_devcache run "Go module cache" y "go build re-downloads modules (needs network)" "$(sz "$HOME/go/pkg/mod")" -- go clean -modcache
    fi
    clean "GPU shader caches" y "rebuilt by the driver the first time a game or app needs them" "$C/mesa_shader_cache" "$HOME/.nv/GLCache" "$C/nvidia" "$C"/radv_builtin_shaders*
    clean "File indexer cache" y "tracker3 index, rebuilt in the background" "$C/tracker3"
    INFO=i_tmp clean "Old files in /tmp" y "your plain files not touched for $TMP_DAYS days (MAINTENANCE_TMP_DAYS)" "${tmpfiles[@]}"
    INFO=i_trash clean "Trash on every drive" n "files you deleted in the file manager, gone for good" "${trashfiles[@]}"
    clean "VS Code caches"   n "close VS Code first; rebuilt on start" "$HOME/.config/Code/Cache" "$HOME/.config/Code/CachedData" "$HOME/.config/Code/CachedExtensionVSIXs" "$HOME/.config/Code/Code Cache" "$HOME/.config/Code/GPUCache"
    clean "C/C++ IntelliSense cache" n "close VS Code first; rebuilt when you open C/C++ code" "$C/vscode-cpptools"
    clean "Chrome cache"     n "close Chrome first; pages load slower once" "$C/google-chrome"
    INFO=i_chrome clean "Chrome site caches" n "close Chrome first; Service Worker CacheStorage only, never IndexedDB or cookies" "$HOME"/.config/google-chrome/*/"Service Worker"/CacheStorage "$HOME"/.config/google-chrome/*/"Service Worker"/ScriptCache
    INFO=i_chromeai clean "Chrome on-device AI model" n "close Chrome first; ~4 GB, Chrome downloads it again (chrome://on-device-internals)" "$HOME/.config/google-chrome/OptGuideOnDeviceModel"
    clean "Discord cache"    n "close Discord first; rebuilt on start" "$HOME/.config/discord/Cache" "$HOME/.config/discord/Code Cache" "$HOME/.config/discord/GPUCache"
    clean "Spotify cache"    n "close Spotify first; songs re-download" "$C/spotify"
    echo -e "\n${DIM}Biggest folders in ~/.cache (not touched unless listed above; models and data can live here):${RST}"
    du -sh "$C"/* 2>/dev/null | sort -rh | head -8 | sed 's/^/  /'
fi

if section "Leftovers and duplicates (review each)"; then
    mapfile -t dupfonts < <(dup_fonts)
    mapfile -t oldext < <(vscode_old_ext)
    mapfile -t olddl < <(old_downloads)
    mapfile -t builds < <(build_dirs | awk -F'|' '$1 != "python venv" {print $2}')
    INFO=i_fonts clean "Duplicate fonts" y "~/.fonts files identical to ones in ~/.local/share/fonts" "${dupfonts[@]}"
    INFO=i_trashbak clean "Trash.bak" n "~/.local/share/Trash.bak, not made by the desktop: look inside first" "$HOME/.local/share/Trash.bak"
    INFO=i_vscodeext clean "Old VS Code extension versions" n "close VS Code first; only versions extensions.json does not use" "${oldext[@]}"
    INFO=i_codeium clean "Codeium index" n "rebuilt in the background the next time you use it (slow once)" "$HOME/.codeium/database" "$HOME/.codeium/ws-browser"
    INFO=i_downloads clean "Old Downloads" n "items in ~/Downloads not touched for $DOWNLOADS_DAYS days (MAINTENANCE_DOWNLOADS_DAYS)" "${olddl[@]}"
    INFO=i_builds clean "Build folders" n "node_modules, Rust target, __pycache__ in your project folders; venvs are never offered" "${builds[@]}"
fi

if section "System (needs sudo)"; then
    if sudo -v; then
        mapfile -t rc < <(rc_pkgs)
        mapfile -t kpkgs < <(kernel_pkgs $(kernels_old))
        mapfile -t mods < <(orphan_modules)
        run "APT package cache" y "downloaded .deb files" "$(sz /var/cache/apt/archives)" -- sudo apt-get clean
        run "APT package lists" n "run 'sudo apt update' before installing anything again" "$(sz /var/lib/apt/lists)" -- sudo find /var/lib/apt/lists -mindepth 1 -delete
        [ ${#rc[@]} -eq 0 ] || INFO=i_rc run "Leftover package configs" y "removed packages whose config files remain; apt asks again" "${#rc[@]} packages" -- sudo apt-get purge "${rc[@]}"
        pkgs=$(apt-get -s autoremove 2>/dev/null | awk '/^Remv/{print $2}' | tr '\n' ' ')
        [ -z "$pkgs" ] || run "Unused packages" n "apt asks again before removing: ${pkgs:0:120}" "$(wc -w <<<"$pkgs") packages" -- sudo apt-get autoremove --purge
        [ ${#kpkgs[@]} -eq 0 ] || INFO=i_kernels run "Old kernels" n "keeps the running, the newest and one fallback kernel; apt asks again" "$(kernels_old | wc -l) kernels, ${#kpkgs[@]} packages" -- sudo apt-get purge "${kpkgs[@]}"
        [ ${#mods[@]} -eq 0 ] || INFO=i_modules run "Leftover kernel module folders" n "/lib/modules folders of kernels that are gone" "$(sz "${mods[@]}")" -- sudo rm -rf -- "${mods[@]}"
        [ -z "$(find /var/crash -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ] ||
            run "Crash reports" y "/var/crash" "$(sz /var/crash)" -- sudo find /var/crash -mindepth 1 -delete
        [ -z "$(find /var/lib/systemd/coredump -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ] ||
            run "Core dumps" y "/var/lib/systemd/coredump" "$(sz /var/lib/systemd/coredump)" -- sudo find /var/lib/systemd/coredump -mindepth 1 -delete
        run "System journal" y "keeps the last $JOURNAL_DAYS days (MAINTENANCE_JOURNAL_DAYS); memlog-report only sees OOM kills that recent" "$(sz /var/log/journal)" -- sudo journalctl --vacuum-time="${JOURNAL_DAYS}d"
        # rotated copies only (syslog.1, *.gz, ...): active logs, the journal and samba's per-client logs (log.10.1.2.3) are not matched
        ROT=(find /var/log -maxdepth 2 -type f \( -name '*.gz' -o -name '*.xz' -o -name '*.old' -o -name '*.[0-9]' \) -not -path '/var/log/journal/*' -not -path '/var/log/samba/*')
        rot_bytes=$({ "${ROT[@]}" -printf '%s\n' 2>/dev/null || true; } | awk '{s+=$1} END{print s+0}')   # find exits 1 on unreadable dirs
        [ "$rot_bytes" -eq 0 ] ||
            run "Rotated logs" y "old syslog.1, *.gz and similar in /var/log; active logs stay" "$(numfmt --to=iec "$rot_bytes")" -- sudo "${ROT[@]}" -delete
        if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
            dangling=$(docker images -f dangling=true -q | wc -l)
            [ "$dangling" -eq 0 ] || INFO=i_docker run "Docker unused images" n "untagged leftovers of rebuilds; docker asks again" "$dangling images" -- docker image prune
        fi
        old=$(snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' || true)
        if [ -n "$old" ] && ask "Old snap revisions" n "disabled versions kept after snap updates" "$(wc -l <<<"$old") revisions"; then
            while read -r name rev; do sudo snap remove "$name" --revision="$rev"; done <<<"$old"
        fi
    else
        echo -e "${YLW}sudo not available, skipping${RST}"
    fi
fi

echo -e "\n${GRN}Done.${RST} $deleted group(s) cleaned."
free_report after
