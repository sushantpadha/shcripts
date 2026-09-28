#!/bin/bash
# Append one memory snapshot line to the log. Run every minute by the tray app.
# Read-only: it only reports, never kills or changes anything.
# Line: <date> <time>  avail_mb=N swap_mb=N psi=N  top=prog:MB prog:MB ...
umask 077   # log lists running program names: keep it private
SHCRIPTS_DIR="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[ -f "$SHCRIPTS_DIR/.env" ] && { set -a; source "$SHCRIPTS_DIR/.env"; set +a; }   # MEMORY_WARN_MB lives here
LOG="${MEMLOG:-$SHCRIPTS_DIR/logs/memlog.txt}"
MAX=$((5 * 1024 * 1024))   # rotate at 5 MB

mkdir -p "$(dirname "$LOG")"
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt "$MAX" ] && mv "$LOG" "$LOG.old"

read -r avail swap < <(free -m | awk '/^Mem:/{a=$7} /^Swap:/{s=$3} END{print a, s}')
psi=$(awk -F'avg10=' '/^some/{split($2,x," "); print x[1]}' /proc/pressure/memory)
top=$(ps -eo rss=,comm= | awk '{a[$2]+=$1} END{for(k in a) printf "%d %s\n", a[k]/1024, k}' \
      | sort -rn | head -5 | awk '{printf "%s%s:%d", (NR>1?" ":""), $2, $1}')

echo "$(date '+%F %T')  avail_mb=$avail swap_mb=$swap psi=$psi  top=$top" >> "$LOG"

# Low-memory popup. Threshold MEMORY_WARN_MB (default 1500), at most once per MEMORY_WARN_COOLDOWN_MIN (default 10). Both in .env.
WARN_MB="${MEMORY_WARN_MB:-1500}"
STAMP="${STAMP:-${XDG_RUNTIME_DIR:-/tmp}/memlog-warned}"
if [ "$avail" -lt "$WARN_MB" ] && { [ ! -f "$STAMP" ] || [ -n "$(find "$STAMP" -mmin "+${MEMORY_WARN_COOLDOWN_MIN:-10}")" ]; }; then
  notify-send -u critical "Low memory: ${avail} MB free" "Biggest: ${top%% *}. Close something before it freezes."
  touch "$STAMP"
fi
