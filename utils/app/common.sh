#!/bin/bash
# Shared by scripts/app/*.sh. Source it, do not run it.
# Loads .env, sets up one reused ssh connection, reports what is left on the server if a script fails.

ROOT="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
set -a; source "$ROOT/.env"; set +a

REMOTE="$APP_SSH_USER@$APP_SSH_HOST"
REMOTE_DIR="$APP_REMOTE_DIR"
BACKUP_DIR="$APP_BACKUP_DIR"
REMOTE_TMP="${APP_REMOTE_TMP:-/tmp}"          # archives are staged here on the server: needs room for a whole world
SERVER_PROC="${APP_SERVER_PROCESS:-java}"     # process NAME (pgrep) that means "the server is running"

RED="\033[1;31m" YLW="\033[1;33m" GRN="\033[1;32m" CYN="\033[1;36m" DIM="\033[2m" BLD="\033[1m" RST="\033[0m"
warn() { echo -e "${YLW}! $*${RST}"; }
info() { echo -e "${DIM}  $*${RST}"; }
confirm() { local a; read -rp "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

# reuse one ssh connection (login once, persists 10m after last use)
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=${XDG_RUNTIME_DIR:-/tmp}/shcripts-ssh-%C" -o ControlPersist=10m)
ssh() { command ssh "${SSH_OPTS[@]}" "$@"; }
scp() { command scp "${SSH_OPTS[@]}" "$@"; }

layout_warning() {
    echo -e "${BLD}${YLW}ASSUMES PAPER/SPIGOT LAYOUT: three folders <world>, <world>_nether, <world>_the_end.${RST}"
    echo -e "${BLD}${YLW}Vanilla keeps the dimensions inside <world>/ (missing folders are skipped, not an error).${RST}"
    echo
}

# world_dirs <world>: the world folders that exist on the server, one per line
world_dirs() {
    ssh "$REMOTE" "cd '$REMOTE_DIR' && for d in '$1' '$1_nether' '$1_the_end'; do [ -d \"\$d\" ] && echo \"\$d\"; done; true"
}

# quote_list a b c -> 'a' 'b' 'c'  (for building remote commands)
quote_list() { printf "'%s' " "$@"; }

# remote_bytes <dir>... : total size of these folders inside REMOTE_DIR
remote_bytes() { ssh "$REMOTE" "cd '$REMOTE_DIR' && du -sbc $(quote_list "$@") | tail -1 | cut -f1"; }

# need_space <server dir> <bytes> <what for>: warn and ask when the server has less room than needed
need_space() {
    local free
    free=$(ssh "$REMOTE" "df -B1 --output=avail '$1' | tail -1" | tr -d ' ')
    if [ "$free" -lt "$2" ]; then
        warn "low space on the server in $1: $3 needs about $(numfmt --to=iec "$2"), only $(numfmt --to=iec "$free") free"
        confirm "Continue anyway?" || exit 0
    else
        info "space ok in $1: $(numfmt --to=iec "$free") free, $3 needs about $(numfmt --to=iec "$2")"
    fi
}

# on any exit: report failure (+ what is left on server), then close ssh master.
# Scripts set STEP and LEFT as they go.
STEP="startup checks"
LEFT=""
finish() {
    rc=$?
    trap - EXIT
    if [ $rc -ne 0 ]; then
        echo
        echo -e "${RED}FAILED (exit $rc) during: $STEP${RST}"
        if [ -n "$LEFT" ]; then
            echo -e "${YLW}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RST}"
            echo -e "${YLW}! NEEDS ATTENTION - left behind on $REMOTE:${RST}"
            printf '%s\n' "$LEFT" | sed 's/^/! /'
            echo -e "${YLW}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${RST}"
        fi
    fi
    ssh -O exit "$REMOTE" 2>/dev/null || true
}
trap finish EXIT
