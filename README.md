# shcripts

A modern launcher for organizing and running shell scripts. Categorized by folder, tracks run history with last 3 executions, opens scripts in terminal windows, idle notifications via systemd.

## Setup (2 minutes)

```bash
cd ~/shcripts
bash launcher/setup.sh
python3 launcher/launcher.py
```

That's it. The setup script:
- Installs PyQt5
- Creates `scripts/` and `logs/` directories
- Sets up systemd user timer for idle notifications (24h check, hourly reminder)
- Creates app menu entry

## Do this
Add keyboard shortcut `Super+B` or something to open the launcher.

## Directory Structure

```
~/shcripts/
├── launcher/               ← the app (don't edit often)
│   ├── launcher.py
│   ├── setup.sh
│   └── README.md          ← detailed docs
├── scripts/                ← your scripts (organized by category)
│   ├── gpu/
│   ├── system/
│   ├── dev/
│   └── maintenance/
├── logs/                   ← auto-generated per-run logs
├── .history.json           ← auto-generated run history (gitignored)
├── .lastopen              ← auto-generated idle marker (gitignored)
├── .gitignore
└── README.md              ← this file
```

## Add Your First Script

```bash
mkdir -p ~/shcripts/scripts/gpu
cat > ~/shcripts/scripts/gpu/nvidia_disable.sh <<'EOF'
#!/usr/bin/env bash
################################################################################
# Script: nvidia_disable
# Description: Disable NVIDIA GPU and switch to integrated graphics
# Author: you
# Created: 2025-05-25
################################################################################

set -euo pipefail
echo "Disabling NVIDIA..."
# your code here
EOF
chmod +x ~/shcripts/scripts/gpu/nvidia_disable.sh
```

Restart the launcher — your script appears under the `gpu` category.

## Script Metadata

The launcher parses the header block of each `.sh` file:

```bash
################################################################################
# Script: name_here
# Description: One-line explanation shown in UI
# Author: your name
# Created: 2025-05-25
# Last Modified: 2025-05-25
################################################################################
```

All optional except **Description**. Click a script in the UI to expand and see full metadata.

## UI Overview

- **Collapsible folders** — organize by category (gpu/, system/, etc.)
- **Expandable descriptions** — click script name to see full metadata
- **Last 3 runs** — status dots (🟢 success, 🔴 failed)
- **[▶ Run]** button — opens script in new terminal window
- **[↺ Rescan]** — reload scripts from disk
- **Idle notifications** — reminds you every hour if you haven't opened app in 24h

## Git Setup

```bash
cd ~/shcripts
git init
git remote add origin https://github.com/yourusername/shcripts.git
git add scripts/ launcher/ .gitignore README.md
git commit -m "initial: shcripts"
git push -u origin main
```

Auto-excluded from git:
- `.history.json` (run metadata)
- `.lastopen` (idle marker)
- `logs/` (per-run logs)

Just commit your `scripts/` folder and the launcher code.

## Hotkey

**GNOME:** Settings → Keyboard → Custom Shortcuts
```
Name: shcripts
Command: python3 ~/shcripts/launcher/launcher.py
Shortcut: Super+S (or your choice)
```

**KDE:** System Settings → Shortcuts → Custom Shortcuts (same command)

## For Full Details

See `launcher/README.md` — covers:
- Detailed UI guide
- Run history schema
- Idle notification tuning
- Terminal detection
- Troubleshooting
- Customization (colors, timeouts, history depth)

## Quick Commands

```bash
# Check timer status
systemctl --user status shcripts-idle.timer

# View idle check logs
journalctl --user -u shcripts-idle.service -n 10

# Disable idle reminders
systemctl --user disable shcripts-idle.timer

# Re-enable
systemctl --user enable shcripts-idle.timer
```

## License

MIT.