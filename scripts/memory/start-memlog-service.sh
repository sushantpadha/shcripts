#!/bin/bash
# Start the memory-log tray icon (toggle logging from the status bar).
# Safe to run twice: does nothing if already running.
TRAY="$(cd "$(dirname "$0")/../../utils/memory" && pwd)/memlog-tray.py"

if pgrep -f "$TRAY" >/dev/null; then
  echo "memlog tray already running"
  exit 0
fi

PY="${SHCRIPTS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/.venv/bin/python"
[ -x "$PY" ] || PY=python3   # no venv yet: system python
nohup "$PY" "$TRAY" >/dev/null 2>&1 &
echo "memlog tray started"
