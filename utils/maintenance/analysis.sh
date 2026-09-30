#!/bin/bash
# Read-only helpers for scripts/maintenance/clean.sh. Source it, do not run it.
#   a_<id>        short report ("where is the space?"), a_<id>_more = details (the h option)
#   i_<name>      detail text for a delete group (the h option at a delete prompt)
#   list builders (trash_dirs, kernel_*, dup_fonts, ...) shared by the reports and the delete groups
# Needs from clean.sh: colors (CYN DIM BLD YLW RST), sz, ROOT.

MY_UID=$(id -u)
DOWNLOADS_DAYS="${MAINTENANCE_DOWNLOADS_DAYS:-90}"
TMP_DAYS="${MAINTENANCE_TMP_DAYS:-7}"
read -ra PROJECT_DIRS <<<"${MAINTENANCE_PROJECT_DIRS:-$HOME/projects $HOME/Documents}"
read -ra REVIEW_DIRS <<<"${MAINTENANCE_REVIEW_DIRS:-$HOME/Downloads $HOME/Documents $HOME/Desktop $HOME/Videos $HOME/Pictures $HOME/Music}"
FS_TYPES=ext4,btrfs,xfs,ntfs,ntfs3,fuseblk,vfat,exfat

top() { head -n "${1:-5}" | sed 's/^/  /'; }

# ── list builders ─────────────────────────────────────────────────────────────

# every trash folder of this user: home, each mount root, ~/.Trash-UID
trash_dirs() {
    {
        echo "$HOME/.local/share/Trash"; echo "$HOME/.Trash-$MY_UID"
        findmnt -rno TARGET -t "$FS_TYPES" | sed "s|/*\$||; s|\$|/.Trash-$MY_UID|; p; s|/.Trash-$MY_UID\$|/.Trash/$MY_UID|"
    } | while read -r d; do readlink -f "$d"; done | sort -u | while read -r d; do [ -d "$d/files" ] && echo "$d"; done   # ~/.local/share/Trash can be a symlink to a mount's trash
    return 0
}

kernel_versions() {   # every kernel version that still has an installed image/modules/headers package
    dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 2>/dev/null |
        awk '$1=="ii" && match($2, /^linux-(image|modules|modules-extra|headers)-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$/) {sub(/^linux-[a-z-]*-/, "", $2); print $2}' |
        sort -uV
}
kernels_old() {       # every kernel except: the running one, the newest, and the newest older one that has an image (a fallback to boot)
    local run keep fb imgs
    run=$(uname -r); keep=$(kernel_versions | tail -n1)
    imgs=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | awk '$1=="ii"{sub("linux-image-","",$2); print $2}')
    fb=$(printf '%s\n%s\n' "$imgs" "$run" | sort -uV | grep -B1 -xF "$run" | head -n1)
    kernel_versions | grep -vxF -e "$run" -e "$keep" -e "$fb" || true
}
kernel_pkgs() {       # kernel_pkgs <version>...: installed packages that belong to those kernels
    local v
    for v in "$@"; do
        dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk -v v="$v" '
            $1=="ii" && ($2 ~ ("^linux-(image|image-unsigned|modules|modules-extra|headers|tools|modules-nvidia-[0-9a-z.-]+)-" v "$") ||
                         $2 ~ ("^linux-hwe-[0-9.]+-(headers|tools)-" v "$")) {print $2}'
    done
}
orphan_modules() {    # /lib/modules folders of kernels that are no longer installed (never the running one)
    local d v have; have=$(kernel_versions)
    for d in /lib/modules/*/; do
        v=$(basename "$d")
        [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] || continue   # only real kernel version folders
        [ "$v" = "$(uname -r)" ] || grep -qxF "$v" <<<"$have" || echo "${d%/}"
    done
    return 0
}
rc_pkgs() { dpkg -l 2>/dev/null | awk '/^rc/{print $2}'; }

dup_fonts() {         # ~/.fonts files that are byte-identical to a font in ~/.local/share/fonts
    local f g
    for f in "$HOME"/.fonts/*; do
        [ -f "$f" ] || continue
        g=$(find "$HOME/.local/share/fonts" -name "${f##*/}" -type f -print -quit 2>/dev/null)
        if [ -n "$g" ] && cmp -s "$f" "$g"; then echo "$f"; fi
    done
    return 0
}

vscode_old_ext() {    # older versions of extensions installed several times, not referenced by extensions.json
    local e="$HOME/.vscode/extensions" id d
    [ -f "$e/extensions.json" ] || return 0
    ls "$e" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+.*$//' | sort | uniq -d | while read -r id; do
        ls -d "$e/$id"-[0-9]* 2>/dev/null | sort -V | head -n -1 | while read -r d; do
            grep -qF "${d##*/}" "$e/extensions.json" || echo "$d"
        done
    done
    return 0
}

build_dirs() {        # kind|path for node_modules, Rust target, __pycache__ and .venv under PROJECT_DIRS
    local r d
    for r in "${PROJECT_DIRS[@]}"; do
        [ -d "$r" ] && find "$r" -xdev -maxdepth 6 -type d \( -name node_modules -o -name target -o -name __pycache__ -o -name .venv \) -not -path '*/vscode-server/*' -not -path '*/.vscode*/*' -prune -print 2>/dev/null
    done | while read -r d; do
        case "${d##*/}" in
            target) [ -f "${d%/*}/Cargo.toml" ] && echo "rust target|$d" ;;
            node_modules) echo "node_modules|$d" ;;
            __pycache__) echo "__pycache__|$d" ;;
            .venv) echo "python venv|$d" ;;
        esac
    done
    return 0
}
old_downloads() { find "$HOME/Downloads" -mindepth 1 -maxdepth 1 -mtime "+$DOWNLOADS_DAYS" 2>/dev/null; }
old_tmp() {           # your own plain files in /tmp untouched for TMP_DAYS days (no sockets, no app dirs)
    find /tmp -xdev -type f -user "$USER" -mtime "+$TMP_DAYS" -atime "+$TMP_DAYS" \
        -not -path '/tmp/claude-*' -not -path '/tmp/tmux-*' -not -path '/tmp/ssh-*' -not -path '/tmp/.*' 2>/dev/null
}
chrome_tag() {
    case "$1" in
        "Service Worker") echo "site offline caches (CacheStorage) + registrations" ;;
        IndexedDB|"File System"|"Local Storage"|WebStorage|"Session Storage") echo "SITE DATA: web apps' saved data, do not delete" ;;
        Extensions) echo "installed extensions" ;;
        OptGuideOnDeviceModel) echo "Chrome's on-device AI model; Chrome downloads it again" ;;
        History|Cookies|"Login Data"|Bookmarks|Favicons|"Web Data") echo "your personal data, keep" ;;
        *) echo "" ;;
    esac
}

# ── analysis reports: short (a_x) and detailed (a_x_more) ─────────────────────

a_fs() {
    df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs | sed 's/^/  /'
    local src img app blk
    src=$(findmnt -no SOURCE -T "$HOME" | sed 's/\[.*//')
    if [[ "$src" == /dev/loop* ]]; then
        img=$(losetup -nO BACK-FILE "$src" 2>/dev/null)
        app=$(stat -c %s "$img"); blk=$(( $(stat -c %b "$img") * $(stat -c %B "$img") ))
        echo -e "\n  ${YLW}Your home is inside an image file: $img${RST}"
        echo "  Free space in home = free space INSIDE the image."
        if [ "$blk" -ge $(( app * 98 / 100 )) ]; then echo "  The image is fully allocated: deleting files in home does not free space on the drive holding it."
        else echo "  The image is sparse: freed space can be returned to the drive with fstrim."; fi
    fi
}
a_fs_more() {
    findmnt -t "$FS_TYPES" -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,OPTIONS | cut -c1-150 | sed 's/^/  /'
    echo; swapon --show | sed 's/^/  /'
    echo -e "\n  ${DIM}fuseblk = NTFS through ntfs-3g (slow, no permissions). loop = a file mounted as a disk.${RST}"
}

a_home() { timeout 120 du -xh --max-depth=1 "$HOME" 2>/dev/null | sort -rh | sed 1d | top 8; }
a_home_more() {
    echo -e "  ${DIM}hidden folders are where apps keep caches, settings and data${RST}"
    timeout 120 du -xh --max-depth=2 "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" "$HOME/snap" 2>/dev/null | sort -rh | sed 1d | top 25
}

a_big() { find "$HOME" -xdev -type f -size +500M -printf '%s %TY-%Tm-%Td %p\n' 2>/dev/null | sort -rn | awk '{printf "%6.1fG  modified %s  %s\n", $1/1073741824, $2, $3}' | top 6; }
a_big_more() {
    find "$HOME" -xdev -type f -size +100M -printf '%s %TY-%Tm-%Td %p\n' 2>/dev/null | sort -rn | awk '{printf "%6.1fG  modified %s  %s\n", $1/1073741824, $2, $3}' | top 30
    echo -e "  ${DIM}files over 100 MB, oldest modification date is a hint that you may not need it${RST}"
}

a_tools() {
    local p
    for p in "$HOME/.ghcup" "$HOME/.rustup" "$HOME/.cargo" "$HOME/.cabal" "$HOME/go" "$HOME/.nvm" "$HOME/.local/share/uv" "$HOME/.local/share/claude" /usr/local/cuda-* /usr/local/go /opt/nvidia; do
        [ -e "$p" ] && [ ! -L "$p" ] && printf '  %-7s %s\n' "$(sz "$p")" "$p"
    done
    return 0
}
a_tools_more() {
    echo "  Haskell (ghcup): $(ls "$HOME/.ghcup/ghc" 2>/dev/null | tr '\n' ' ')   remove one: ghcup rm ghc <version>, then ghcup gc"
    echo "  Rust toolchains: $(ls "$HOME/.rustup/toolchains" 2>/dev/null | tr '\n' ' ')   remove one: rustup toolchain uninstall <name>"
    echo "  Node (nvm):      $(ls "$HOME/.nvm/versions/node" 2>/dev/null | tr '\n' ' ')   remove one: nvm uninstall <version>"
    echo "  CUDA:            $(ls -d /usr/local/cuda-* 2>/dev/null | tr '\n' ' ')   installed by apt (cuda-toolkit-*); remove with apt, not rm"
    echo "  uv:              python builds and tools live in ~/.local/share/uv (not a cache; only the cache is offered for deletion)"
    echo "  ~/.local/share/claude: downloaded Claude Code versions"
    echo -e "  ${DIM}The script never removes toolchains itself: you decide which versions you still build with.${RST}"
}

a_kernels() {
    echo "  running: $(uname -r)   newest installed: $(kernel_versions | tail -n1)"
    echo "  kernel versions with installed packages: $(kernel_versions | wc -l)   removable (all but running, newest and one fallback): $(kernels_old | wc -l)"
    echo "  leftover /lib/modules folders of removed kernels: $(orphan_modules | wc -l)"
    printf '  /boot %s   /usr/src %s   /lib/modules %s\n' "$(sz /boot)" "$(sz /usr/src)" "$(sz /lib/modules)"
}
a_kernels_more() {
    echo "  installed: $(kernel_versions | tr '\n' ' ')"
    echo "  would be purged: $(kernels_old | tr '\n' ' ')"
    echo "  leftover module folders: $(orphan_modules | tr '\n' ' ')"
    echo -e "  ${DIM}Keeps the running kernel, the newest one and one older fallback, so you can still boot if an update breaks.${RST}"
}

a_pkgs() {
    echo "  residual-config packages (removed, config left): $(rc_pkgs | wc -l)   unused (autoremove): $(apt-get -s autoremove 2>/dev/null | grep -c '^Remv')"
    echo "  disabled snap revisions: $(snap list --all 2>/dev/null | grep -c disabled)"
    echo "  biggest installed packages:"
    dpkg-query -W -f '${Installed-Size} ${Package}\n' 2>/dev/null | sort -rn | awk '{printf "    %6.0fM  %s\n", $1/1024, $2}' | head -n 6
}
a_pkgs_more() {
    dpkg-query -W -f '${Installed-Size} ${Package}\n' 2>/dev/null | sort -rn | awk '{printf "    %6.0fM  %s\n", $1/1024, $2}' | head -n 25
    echo -e "  ${DIM}Packages you installed yourself: apt-mark showmanual. Why is X installed: apt-cache rdepends --installed X${RST}"
}

a_builds() {
    local n; n=$(build_dirs | wc -l)
    echo "  $n build folders under: ${PROJECT_DIRS[*]}"
    build_dirs | while IFS='|' read -r k d; do printf '%s\t%s\t%s\n' "$(du -sk "$d" | cut -f1)" "$k" "$d"; done | sort -rn | head -n 5 |
        awk -F'\t' '{printf "    %6.0fM  %-13s %s\n", $1/1024, $2, $3}'
}
a_builds_more() {
    build_dirs | while IFS='|' read -r k d; do printf '%s\t%s\t%s\t%s\n' "$(du -sk "$d" | cut -f1)" "$k" "$(date -r "$d" +%F)" "$d"; done | sort -rn | head -n 30 |
        awk -F'\t' '{printf "    %6.0fM  %-13s modified %s  %s\n", $1/1024, $2, $3, $4}'
    echo -e "  ${DIM}node_modules, Rust target and __pycache__ are rebuilt by npm/cargo/python. A python venv is only listed, never offered for deletion.${RST}"
}

a_old() {
    local items; mapfile -t items < <(old_downloads)
    echo "  ${#items[@]} items in ~/Downloads not touched for $DOWNLOADS_DAYS days, total $(sz "${items[@]}")"
    [ ${#items[@]} -eq 0 ] || printf '%s\n' "${items[@]}" | while read -r f; do printf '%s\t%s\n' "$(du -sk "$f" | cut -f1)" "$f"; done | sort -rn | head -n 5 | awk -F'\t' '{printf "    %6.0fM  %s\n", $1/1024, $2}'
}
a_old_more() {
    old_downloads | while read -r f; do printf '%s\t%s\t%s\n' "$(du -sk "$f" | cut -f1)" "$(date -r "$f" +%F)" "$f"; done | sort -rn | head -n 30 | awk -F'\t' '{printf "    %6.0fM  %s  %s\n", $1/1024, $2, $3}'
    echo -e "  ${DIM}Change the age with MAINTENANCE_DOWNLOADS_DAYS in .env.${RST}"
}

a_trash() { local d; while read -r d; do printf '  %-7s %s\n' "$(sz "$d/files")" "$d"; done < <(trash_dirs); [ -d "$HOME/.local/share/Trash.bak" ] && printf '  %-7s %s  (not made by the desktop: a manual copy?)\n' "$(sz "$HOME/.local/share/Trash.bak")" "$HOME/.local/share/Trash.bak"; return 0; }
a_trash_more() {
    local d
    while read -r d; do echo "  $d"; ls -t "$d/files" 2>/dev/null | head -n 4 | sed 's/^/      /'; done < <(trash_dirs)
    echo -e "  ${DIM}Each drive has its own trash (.Trash-$MY_UID at its top), so emptying the desktop trash can miss most of it.${RST}"
}

a_browsers() {
    local p="$HOME/.config/google-chrome/Default"
    [ -d "$p" ] || { echo "  no Chrome profile"; return 0; }
    echo "  Chrome profile Default ($(sz "$p")):"
    du -sk "$p"/* 2>/dev/null | sort -rn | head -n 6 | while IFS=$'\t' read -r k d; do printf '    %6.0fM  %-22s %s\n' "$((k / 1024))" "${d##*/}" "$(chrome_tag "${d##*/}")"; done
    echo "  Chrome cache (~/.cache/google-chrome): $(sz "$HOME/.cache/google-chrome")   Firefox snap cache: $(sz "$HOME/snap/firefox/common/.cache")"
    echo "  Chrome on-device AI model: $(sz "$HOME/.config/google-chrome/OptGuideOnDeviceModel")   (regenerable; delete group below, or disable it in chrome://flags)"
}
a_browsers_more() {
    du -sk "$HOME/.config/google-chrome/Default"/* 2>/dev/null | sort -rn | head -n 20 | while IFS=$'\t' read -r k d; do printf '    %6.0fM  %-24s %s\n' "$((k / 1024))" "${d##*/}" "$(chrome_tag "${d##*/}")"; done
    echo -e "  ${DIM}Only the HTTP cache (~/.cache/google-chrome) and Service Worker CacheStorage are offered for deletion. IndexedDB and Local Storage can hold data that exists nowhere else (offline docs, chat history).${RST}"
}

a_fonts() {
    local f; mapfile -t f < <(dup_fonts)
    echo "  ${#f[@]} files in ~/.fonts ($(sz "${f[@]}")) are identical copies of fonts already in ~/.local/share/fonts"
}
a_fonts_more() { dup_fonts | head -n 15 | sed 's/^/    /'; echo -e "  ${DIM}Checked byte for byte with cmp; fontconfig reads both folders, so the fonts stay available.${RST}"; }

a_docker() {
    command -v docker >/dev/null && docker info >/dev/null 2>&1 || { echo "  docker not installed or not reachable"; return 0; }
    docker system df | sed 's/^/  /'
}
a_docker_more() { command -v docker >/dev/null && docker info >/dev/null 2>&1 || return 0; docker images | head -n 15 | sed 's/^/  /'; echo; docker ps -a | head -n 10 | sed 's/^/  /'; docker volume ls | head -n 10 | sed 's/^/  /'; }

a_other() {   # every drive except the ones / and home live on, and the EFI partition
    local m src skip1 skip2
    skip1=$(findmnt -no SOURCE -T "$HOME" | sed 's/\[.*//'); skip2=$(findmnt -no SOURCE /)
    findmnt -rno TARGET,SOURCE -t "$FS_TYPES" | while read -r m src; do
        src=${src%%[*}
        if [ "$src" = "$skip1" ] || [ "$src" = "$skip2" ] || [[ "$m" == /boot/* ]]; then continue; fi
        echo "  $m"; timeout 90 du -xh --max-depth=1 "$m" 2>/dev/null | sort -rh | sed 1d | head -n 6 | sed 's/^/    /'
    done
    return 0
}
a_other_more() { echo -e "  ${DIM}Other drives are listed for information only. This script never offers to delete anything there except your trash.${RST}"; a_other; }

a_review() {
    local d t; mapfile -t t < <(trash_dirs)
    printf '  %-8s %s\n' "$(sz "${t[@]/%//files}")" "Trash on every drive (${#t[@]} folders)"
    for d in "${REVIEW_DIRS[@]}"; do [ -d "$d" ] && printf '  %-8s %s\n' "$(sz "$d")" "$d"; done
    return 0
}
a_review_more() {
    local d
    for d in "${REVIEW_DIRS[@]}"; do
        [ -d "$d" ] || continue
        printf '  %s  (%s, %s files, newest change %s)\n' "$d" "$(sz "$d")" "$(find "$d" -type f 2>/dev/null | wc -l)" "$(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -n1)"
        du -sk "$d"/* 2>/dev/null | sort -rn | head -n 3 | awk -F'\t' '{printf "      %6.0fM  %s\n", $1/1024, $2}'
    done
    echo -e "  ${DIM}Change the list with MAINTENANCE_REVIEW_DIRS in .env. Nothing here is ever deleted by this script.${RST}"
}
a_loose() {
    local f; mapfile -t f < <(find "$HOME" -maxdepth 1 -type f ! -name '.*')
    echo "  ${#f[@]} loose files in $HOME (not in a folder), $(sz "${f[@]}")"
    find "$HOME" -maxdepth 1 -type f ! -name '.*' -printf '%s\t%TY-%Tm-%Td\t%f\n' | sort -rn | head -n 6 | awk -F'\t' '{printf "    %7.1fM  %s  %s\n", $1/1048576, $2, $3}'
}
a_loose_more() {
    find "$HOME" -maxdepth 1 -type f ! -name '.*' -printf '%s\t%TY-%Tm-%Td\t%f\n' | sort -rn | awk -F'\t' '{printf "    %7.1fM  %s  %s\n", $1/1048576, $2, $3}' | head -n 40
    echo -e "  ${DIM}Scratch files, .save/.out leftovers and old downloads tend to collect here.${RST}"
}

# run_reports <title> <id:title>...: show each report, h = details, q = stop
run_reports() {
    local title=$1 item id a; shift
    echo -e "\n${BLD}── $title ──${RST}"
    for item in "$@"; do
        id=${item%%:*}
        echo -e "\n${CYN}${item#*:}${RST}"
        "a_$id" || true
        read -rp "  [Enter] next  [h] details  [q] stop: " a || a=q
        if [[ "$a" =~ ^[Hh]$ ]]; then
            "a_${id}_more" || true
            read -rp "  [Enter] next  [q] stop: " a || a=q
        fi
        if [[ "$a" =~ ^[Qq]$ ]]; then return 0; fi
    done
}

# id:title, in the order they are shown
REPORTS_SPACE=(fs:"Filesystems and free space" home:"Biggest folders in your home" kernels:"Kernels and boot files"
    pkgs:"Installed packages" builds:"Build folders in your projects" browsers:"Browser data" fonts:"Duplicate fonts" docker:"Docker")
REPORTS_REVIEW=(review:"Sizes of the folders you review by hand" old:"Old files in Downloads" trash:"Trash on every drive"
    loose:"Loose files in your home" big:"Big files in your home" tools:"Developer tools and versions" other:"Data on other drives")


# ── detail texts for delete groups (h at the prompt). Local variables of the caller (found) are visible here.

i_paths() { echo -e "  ${DIM}biggest items:${RST}"; du -sh "${found[@]}" 2>/dev/null | sort -rh | head -n 20 | sed 's/^/    /'; }
i_trash() {
    local d; echo -e "  ${DIM}folders emptied (files + info only; the folder stays):${RST}"
    while read -r d; do printf '    %-7s %s\n' "$(sz "$d/files")" "$d"; done < <(trash_dirs)
    echo -e "  ${DIM}Deleted for good, not recoverable. ~/.local/share/Trash.bak is a separate group.${RST}"
}
i_trashbak() { i_paths; echo -e "  ${DIM}Not created by the desktop or by shcripts (a folder named Trash.bak): probably a manual copy of an old trash. Look inside before deleting.${RST}"; }
i_devcache() {
    echo "    ~/.ghcup/cache     downloaded GHC/HLS installers        (ghcup re-downloads when needed)"
    echo "    ~/.cabal/packages  Hackage index + package tarballs     (cabal update / build re-downloads)"
    echo "    go mod cache       downloaded Go modules                (go build re-downloads; needs network)"
    echo "    ~/.cargo/registry  crate downloads and unpacked sources (cargo re-downloads; needs network)"
    echo -e "  ${DIM}Offline builds stop working until the packages are fetched again.${RST}"
}
i_chrome() { a_browsers_more; }
i_chromeai() { echo -e "  ${DIM}OptGuideOnDeviceModel holds Chrome's local AI model (weights.bin). It is re-downloaded when a feature needs it. To stop that for good: chrome://flags, search 'on device model'.${RST}"; i_paths; }
i_fonts() { a_fonts_more; }
i_vscodeext() { echo -e "  ${DIM}older versions of extensions that are installed more than once, not listed in extensions.json:${RST}"; vscode_old_ext | sed 's/^/    /'; }
i_downloads() { a_old_more; }
i_builds() { a_builds_more; }
i_tmp() { echo -e "  ${DIM}your regular files in /tmp not modified or read for $TMP_DAYS days (sockets and app folders are never touched):${RST}"; old_tmp | head -n 25 | sed 's/^/    /'; }
i_rc() { echo -e "  ${DIM}packages already removed whose config files were left behind; purging deletes only those config files:${RST}"; rc_pkgs | head -n 60 | tr '\n' ' ' | fold -s -w 100 | sed 's/^/    /'; echo; }
i_kernels() {
    echo "    running: $(uname -r)   newest: $(kernel_versions | tail -n1)   (both kept, plus one older fallback)"
    echo "    purged versions: $(kernels_old | tr '\n' ' ')"
    echo -e "  ${DIM}packages (apt asks once more, grub is updated automatically):${RST}"
    kernel_pkgs $(kernels_old) | tr '\n' ' ' | fold -s -w 100 | sed 's/^/    /'; echo
}
i_modules() { echo -e "  ${DIM}/lib/modules folders with no installed kernel package; usually DKMS leftovers:${RST}"; orphan_modules | while read -r d; do printf '    %-7s %s\n' "$(sz "$d")" "$d"; done; }
i_codeium() { echo -e "  ${DIM}Codeium/Windsurf language-server index and browser workspace. Rebuilt in the background next time you use it (slow once).${RST}"; i_paths; }
i_docker() { docker images -f dangling=true | sed 's/^/    /'; echo -e "  ${DIM}dangling = untagged images left after a rebuild. Docker asks again.${RST}"; }
i_snapcache() { echo -e "  ${DIM}per-snap caches in ~/snap/<app>/common/.cache; the app rebuilds them:${RST}"; i_paths; }
