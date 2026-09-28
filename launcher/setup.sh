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
if ! pip install textual python-dotenv PyQt5 matplotlib numpy --break-system-packages -q 2>/dev/null; then
  echo "✗ Failed to install Python deps (textual python-dotenv PyQt5 matplotlib numpy)"
  exit 1
fi
echo "  ✓ Python deps"

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
Terminal=true
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
echo "  ✓ Setup complete. Run: python3 $LAUNCHER_DIR/launcher.py"
echo "  Config: cp .env.example .env   Scripts: GLOSSARY.md"
