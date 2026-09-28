#!/usr/bin/env bash
# Install deps into .venv, add an app menu entry, enable the idle reminder timer.
# Safe to rerun. Writes only under .venv, ~/.local/share/applications, ~/.config/systemd/user.
set -euo pipefail

SHCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$SHCRIPTS_DIR/launcher/launcher.py"
VENV="$SHCRIPTS_DIR/.venv"
PY="$VENV/bin/python"
SYSTEMD_DIR="$HOME/.config/systemd/user"
DESKTOP="$HOME/.local/share/applications/shcripts.desktop"

G="\033[1;32m" R="\033[1;31m" C="\033[1;36m" N="\033[0m"
step() { echo -e "\n${C}[$1/4]${N} $2"; }

command -v python3 >/dev/null || { echo -e "${R}x${N} python3 not found"; exit 1; }
echo -e "${C}shcripts setup${N}  ($SHCRIPTS_DIR)"

step 1 "Python environment: $VENV"
# --system-site-packages: reuse Qt/matplotlib already installed by apt, if any
python3 -m venv --system-site-packages "$VENV" \
    || { echo -e "${R}x${N} venv failed. Try: sudo apt install python3-venv"; exit 1; }
"$PY" -m pip install -q textual python-dotenv PyQt5 matplotlib numpy
echo -e "  ${G}+${N} textual python-dotenv PyQt5 matplotlib numpy"

step 2 "Folders"
mkdir -p "$SHCRIPTS_DIR/scripts" "$SHCRIPTS_DIR/logs"
echo -e "  ${G}+${N} scripts/ logs/"

step 3 "App menu entry: $DESKTOP"
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=shcripts
Comment=Script launcher with run history
Exec=$PY $LAUNCHER
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Utility;
EOF
echo -e "  ${G}+${N} done"

step 4 "Idle reminder timer (hourly check, reminds after 24 h unused)"
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/shcripts-idle.service" <<EOF
[Unit]
Description=shcripts idle checker
After=display-manager.service

[Service]
Type=oneshot
ExecStart=$PY $LAUNCHER --check-idle
Environment=DISPLAY=:0
Environment=SHCRIPTS_DIR=$SHCRIPTS_DIR
EOF
cat > "$SYSTEMD_DIR/shcripts-idle.timer" <<EOF
[Unit]
Description=Run shcripts idle checker hourly
Requires=shcripts-idle.service

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now shcripts-idle.timer
echo -e "  ${G}+${N} shcripts-idle.timer enabled"

echo -e "\n${G}Done.${N} Run: $PY $LAUNCHER"
echo "Config: cp .env.example .env   Scripts: GLOSSARY.md   Hotkey: see README"
