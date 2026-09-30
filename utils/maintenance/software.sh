#!/bin/bash
# Installed-software overview for scripts/maintenance/clean.sh. Source it, do not run it.
# Read-only. software_overview prints compact categories; FULL=1 prints every name.
# Needs from clean.sh: colors (CYN DIM BLD RST).

read -ra SOFTWARE_DIRS <<<"${MAINTENANCE_SOFTWARE_DIRS:-}"

# wrap <max lines>: names from stdin (one per line) -> indented wrapped text
wrap() {
    local max=$1 out
    out=$(paste -sd' ' | fold -s -w 98)
    if [ "${FULL:-0}" = 1 ]; then sed 's/^/    /' <<<"$out"
    else
        head -n "$max" <<<"$out" | sed 's/^/    /'
        [ "$(wc -l <<<"$out")" -le "$max" ] || echo -e "    ${DIM}... (h for the full list)${RST}"
    fi
}
# sw <title> <max lines>: title with count, then the wrapped names read from stdin
sw() {
    local names; names=$(cat)
    [ -n "$names" ] || return 0
    echo -e "  ${BLD}$1${RST} ${DIM}($(wc -l <<<"$names"))${RST}"
    wrap "$2" <<<"$names"
}

apt_manual_groups() {   # "group<TAB>name" for packages you installed by hand; cuda/nvidia/-dev libs are collapsed
    apt-mark showmanual | sort | xargs -r dpkg-query -W -f '${Section}\t${Package}\n' 2>/dev/null | awk -F'\t' '
        function grp(s) {
            sub(".*/", "", s)
            if (s ~ /^(devel|libdevel|interpreters|libs|python|perl|ruby|golang|rust|haskell|java|javascript|cli-mono|metapackages|database)$/) return "development"
            if (s ~ /^(utils|admin|shells|base|text|vcs|kernel|default|oldlibs)$/) return "system & command line"
            if (s ~ /^(net|web|mail|comm|embedded|httpd)$/) return "network"
            if (s ~ /^(video|sound|graphics|gnome|kde|x11|fonts|games)$/) return "desktop & media"
            if (s ~ /^(science|math|tex|doc|editors|electronics|hamradio|misc|translations|localization)$/) return "science, docs, editors"
            return "other"
        }
        $2 ~ /^(cuda-|libcu|libnpp|libnvjpeg|libnvjitlink|libnvfatbin|libnvptxcompiler|libnvvm|gds-tools|nsight)/ {cuda++; next}
        $2 ~ /^(libnvidia-|nvidia-)/ {nv++; next}
        $2 ~ /^lib.*-dev$/ {dev++; next}
        {print grp($1) "\t" $2}
        END { if (cuda) print "development\tcuda-*(" cuda ")"; if (nv) print "development\tnvidia-*(" nv ")"; if (dev) print "development\tlib*-dev(" dev ")" }'
}

software_overview() {
    local g n d f
    echo -e "${BLD}apt: packages you installed by hand${RST} ${DIM}(dependencies and the base system are not listed)${RST}"
    n=$(apt_manual_groups)
    for g in "development" "system & command line" "network" "desktop & media" "science, docs, editors" "other"; do
        awk -F'\t' -v g="$g" '$1 == g {print $2}' <<<"$n" | sw "$g" 3
    done

    echo -e "\n${BLD}other package managers${RST}"
    snap list 2>/dev/null | awk 'NR>1{print $1}' | grep -vE '^(bare|core[0-9]*|snapd.*|gnome-.*|gtk-common-themes|kf[0-9]+-.*|mesa-.*)$' | sw "snap apps" 2
    pip3 list --user --format=freeze 2>/dev/null | cut -d= -f1 | sw "pip (user)" 2
    uv tool list 2>/dev/null | awk '!/^-/ && NF {print $1}' | sw "uv tools" 2
    pipx list --short 2>/dev/null | awk '{print $1}' | sw "pipx" 2
    { ls "$HOME/.nvm/versions/node" 2>/dev/null | sed 's/^/node /'; npm ls -g --depth=0 2>/dev/null | sed -n 's/.*── //p'; } | sw "node (nvm, npm -g)" 2
    { rustup toolchain list 2>/dev/null | awk '{print "rust-" $1}'; cargo install --list 2>/dev/null | awk '/^[a-z]/{gsub(":","",$2); print $1 "@" $2}'; } | sw "rust (rustup, cargo install)" 2
    ghcup list -t ghc,hls,cabal,stack -c installed -r 2>/dev/null | awk '{print $1 "-" $2}' | sw "haskell (ghcup)" 2
    { command -v go >/dev/null && go version | awk '{print "go-" $3}'; ls "$HOME/go/bin" 2>/dev/null; } | sw "go" 2
    grep -h '^Name=' "$HOME"/.local/share/applications/chrome-*-Default.desktop 2>/dev/null | cut -d= -f2 | sort -u | tr ' ' '_' | sw "web apps (Chrome)" 2

    echo -e "\n${BLD}portable and hand-installed${RST} ${DIM}(outside the package managers)${RST}"
    ls "$HOME/.local/bin" 2>/dev/null | sw "~/.local/bin" 3
    ls /usr/local/bin 2>/dev/null | sw "/usr/local/bin (built or copied by hand)" 3
    ls /opt 2>/dev/null | sw "/opt" 2
    find "$HOME" /mnt -maxdepth 4 -iname '*.AppImage' 2>/dev/null | sed 's|.*/||' | sw "AppImages" 2
    while read -r d; do ls "$d" 2>/dev/null | sw "${d/#$HOME/\~}" 2; done < <(portable_dirs)
    for f in "$HOME"/.local/share/applications/*.desktop; do
        grep -q '^Exec=.*\(google-chrome\|/usr/\|env \)' "$f" && continue
        printf '%s->%s\n' "$(grep -m1 '^Name=' "$f" | cut -d= -f2 | tr ' ' '_')" "$(grep -m1 '^Exec=' "$f" | cut -d= -f2- | awk '{print $1}' | tr -d '"' | sed 's|.*/||')"
    done | sw "custom launchers (name -> program)" 3
    return 0
}

# tool-like folders: the ones named in MAINTENANCE_SOFTWARE_DIRS plus utils/tools/install/apps/portable folders found near the top of home and the mounts
portable_dirs() {
    {
        printf '%s\n' "${SOFTWARE_DIRS[@]}"
        find "$HOME" -maxdepth 3 -type d \( -iname utils -o -iname tools -o -iname install -o -iname installs -o -iname apps -o -iname portable -o -iname software \) \
            -not -path '*/.*' -not -path "$HOME/shcripts/*" -not -path '*/node_modules/*' -not -path "$HOME/snap/*" 2>/dev/null
        find /mnt -maxdepth 3 -type d \( -iname utils -o -iname tools -o -iname install -o -iname installs -o -iname apps -o -iname portable -o -iname software \) -not -path '*/.*' 2>/dev/null
    } | grep -v '^$' | sort -u | while read -r d; do [ -d "$d" ] && echo "$d"; done
    return 0
}
