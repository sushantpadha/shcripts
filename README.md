# shcripts

> Read [this chat](https://claude.ai/chat/246f3a9d-929b-48b4-8124-0eb8fd1a8c50).
> On how to download and setup google drive and notion backup scripts.

A modern launcher for organizing and running shell and python scripts. Categorized by folder, tracks run history with last 3 executions, opens scripts in terminal windows, idle notifications via systemd.

## Setup (2 minutes)

```bash
cd ~/shcripts
bash launcher/setup.sh
python3 launcher/launcher.py
```

That's it. The setup script:

* Installs PyQt5
* Creates `scripts/` and `logs/` directories
* Sets up systemd user timer for idle notifications (24h check, hourly reminder)
* Creates app menu entry

## Do this

Add keyboard shortcut `Super+B` or something to open the launcher.

## Directory Structure

```text
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

### Shell

```bash
mkdir -p ~/shcripts/scripts/gpu
cat > ~/shcripts/scripts/gpu/nvidia_disable.sh <<'EOF'
#!/usr/bin/env bash
# Disable NVIDIA GPU and switch to integrated graphics

set -euo pipefail
echo "Disabling NVIDIA..."
# your code here
EOF
chmod +x ~/shcripts/scripts/gpu/nvidia_disable.sh
```

### Python

```bash
mkdir -p ~/shcripts/scripts/gpu
cat > ~/shcripts/scripts/gpu/nvidia_disable.py <<'EOF'
#!/usr/bin/env python3
"""
Disable NVIDIA GPU and switch to integrated graphics.
"""

print("Disabling NVIDIA...")
EOF
chmod +x ~/shcripts/scripts/gpu/nvidia_disable.py
```

Restart the launcher — your script appears under the `gpu` category.

## Script Metadata

The launcher intentionally keeps metadata minimal.

### `.sh`

The first actual comment line becomes the description shown in the UI.

Ignored automatically:

* shebangs
* empty lines

Example:

```bash
#!/usr/bin/env bash
# One-line explanation shown in UI
```

### `.py`

The first line of the module docstring becomes the description shown in the UI.

Example:

```python
"""
One-line explanation shown in UI.

Additional notes here.
"""
```

Only the first line is displayed in the launcher UI.

## UI Overview

* **Collapsible folders** — organize by category (gpu/, system/, etc.)
* **Expandable descriptions** — click script name to see metadata
* **Last 3 runs** — status dots (🟢 success, 🔴 failed)
* **[▶ Run]** button — opens script in new terminal window
* **[↺ Rescan]** — reload scripts from disk
* **Idle notifications** — reminds you every hour if you haven't opened app in 24h

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

* `.history.json` (run metadata)
* `.lastopen` (idle marker)
* `logs/` (per-run logs)

Just commit your `scripts/` folder and the launcher code.

## Hotkey

**GNOME:** Settings → Keyboard → Custom Shortcuts

```text
Name: shcripts
Command: gnome-terminal -- bash -c 'python3 /home/dietcoke/shcripts/launcher/launcher.py; exec bash'
Shortcut: Super+B
```

> [!note]
> It's important to run it in a dedicated terminal window as done using `gnome-terminal` above.

**KDE:** System Settings → Shortcuts → Custom Shortcuts (same command)

## For Full Details

See `launcher/README.md` — covers:

* Detailed UI guide
* Run history schema
* Idle notification tuning
* Terminal detection
* Troubleshooting
* Customization (colors, timeouts, history depth)

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
