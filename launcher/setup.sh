#!/usr/bin/env bash
set -euo pipefail

LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON=$(command -v python3)

if [ -z "$PYTHON" ]; then
  echo "✗ python3 not found. Install it first."
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  shcripts launcher v2 — setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. Python deps
echo "[1/5] Installing Python dependencies..."
if ! pip install PyQt5 --break-system-packages -q 2>/dev/null; then
  echo "✗ Failed to install PyQt5. Try: pip install PyQt5 --break-system-packages"
  exit 1
fi
echo "  ✓ PyQt5"

# 2. Create directory structure
echo "[2/5] Creating directory structure..."
mkdir -p "$HOME/shcripts/scripts"
mkdir -p "$HOME/shcripts/logs"
echo "  ✓ ~/shcripts/{scripts,logs}"

# 3. Desktop shortcut
DESKTOP="$HOME/.local/share/applications/shcripts.desktop"
mkdir -p "$(dirname "$DESKTOP")"
cat > "$DESKTOP" <<EOF
[Desktop Entry]
Name=shcripts
Comment=Script launcher with run history
Exec=$PYTHON $LAUNCHER_DIR/launcher.py
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Utility;
EOF
echo "[3/5] Desktop entry: $DESKTOP"

# 4. Systemd user service + timer for idle notifications
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

# Service: calls --check-idle
cat > "$SYSTEMD_DIR/shcripts-idle.service" <<EOF
[Unit]
Description=shcripts idle checker
After=display-manager.service

[Service]
Type=oneshot
ExecStart=$PYTHON $LAUNCHER_DIR/launcher.py --check-idle
Environment=DISPLAY=:0
EOF

# Timer: runs service every hour
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

echo "[4/5] Systemd timer installed"
echo "  Service: $SYSTEMD_DIR/shcripts-idle.service"
echo "  Timer:   $SYSTEMD_DIR/shcripts-idle.timer"

# 5. Enable and start timer
echo "[5/5] Enabling systemd timer..."
systemctl --user daemon-reload
systemctl --user enable shcripts-idle.timer
systemctl --user start shcripts-idle.timer

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Setup complete!"
echo ""
echo "  Usage:"
echo "    python3 $LAUNCHER_DIR/launcher.py"
echo ""
echo "  Directory structure:"
echo "    ~/shcripts/"
echo "    ├── scripts/          ← put your scripts here"
echo "    │   ├── gpu/"
echo "    │   ├── system/"
echo "    │   └── dev/"
echo "    ├── logs/             ← per-run logs (auto-generated)"
echo "    ├── .history.json     ← run history (auto-generated)"
echo "    └── .lastopen        ← idle timer marker (auto-generated)"
echo ""
echo "  Git setup:"
echo "    cd ~/shcripts && git init"
echo "    echo '.history.json' >> .gitignore"
echo "    echo '.lastopen' >> .gitignore"
echo "    echo 'logs/' >> .gitignore"
echo "    git remote add origin <your-repo>"
echo ""
echo "  Idle notifications:"
echo "    systemctl --user status shcripts-idle.timer"
echo "    systemctl --user disable shcripts-idle.timer  # to turn off"
echo ""
echo "  Logs:"
echo "    journalctl --user -u shcripts-idle.service  # check timer runs"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
