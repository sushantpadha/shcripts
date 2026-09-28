#!/bin/bash
# Summarise memlog.txt: worst moments, and what happened just before the last reboot.
SHCRIPTS_DIR="${SHCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG="${MEMLOG:-$SHCRIPTS_DIR/logs/memlog.txt}"

[ -s "$LOG" ] || [ -s "$LOG.old" ] || { echo "no log data yet: $LOG"; exit 1; }

cat "$LOG.old" "$LOG" 2>/dev/null | awk -v boot="$(uptime -s)" '
{
  ts = $1 " " $2
  top1 = ""
  for (i = 3; i <= NF; i++) {
    if ($i ~ /^top=/) { top1 = substr($i, 5); break }
    split($i, kv, "="); v[kv[1]] = kv[2] + 0
  }
  n++
  if (n == 1) first = ts
  last = ts
  if (n == 1 || v["avail_mb"] < minavail) { minavail = v["avail_mb"]; mints = ts; mintop = top1 }
  if (n == 1 || v["swap_mb"] > maxswap)   { maxswap  = v["swap_mb"];  swapts = ts }
  if (n == 1 || v["psi"] > maxpsi)        { maxpsi   = v["psi"];      psits = ts }
  if (ts < boot) pre[++k] = $0
}
END {
  printf "Snapshots:      %d  (%s  to  %s)\n", n, first, last
  printf "Lowest RAM:     %d MB free   at %s   biggest then: %s\n", minavail, mints, mintop
  printf "Peak swap:      %d MB used   at %s\n", maxswap, swapts
  printf "Peak pressure:  %s%%          at %s\n", maxpsi, psits
  printf "\nLast snapshots before the last reboot (%s):\n", boot
  if (k == 0) print "  none, log started after the last boot"
  for (i = (k > 3 ? k - 2 : 1); i <= k; i++) print "  " pre[i]
}'

echo
echo "Programs killed for low memory (all boots):"
{
  journalctl -k -b all --no-pager -o short-iso -g 'Out of memory: Killed process' 2>/dev/null |
    awk '/Killed process/ {
      match($0, /\([^)]*\)/);       name = substr($0, RSTART + 1, RLENGTH - 2)
      match($0, /anon-rss:[0-9]+/); mb = substr($0, RSTART + 9, RLENGTH - 9) / 1024
      printf "  %s  kernel OOM killer   %s (%d MB)\n", substr($1, 1, 19), name, mb }'
  journalctl -b all -u systemd-oomd --no-pager -o short-iso -g 'Killed' 2>/dev/null |
    awk '/Killed \// {
      match($0, /Killed [^ ]+/); n = split(substr($0, RSTART + 7, RLENGTH - 7), p, "/")
      printf "  %s  systemd-oomd        %s\n", substr($1, 1, 19), p[n] }'
} | sort | tail -10 | { grep . || echo "  none"; }
