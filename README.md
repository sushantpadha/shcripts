# shcripts

My scripts and system configs for one Linux laptop (Ubuntu, GNOME), with a terminal launcher to browse and run them.

What each script does: [GLOSSARY.md](GLOSSARY.md). Details live in each script's header.

## Setup

```bash
git clone https://github.com/sushantpadha/shcripts ~/shcripts     # paths assume ~/shcripts
bash ~/shcripts/launcher/setup.sh
python3 ~/shcripts/launcher/launcher.py
```

`setup.sh` installs the Python deps, adds an app menu entry, and enables the idle reminder timer.

## Services

Idle reminder (a notification if the launcher hasn't been opened in 24 h, checked hourly):

```bash
systemctl --user enable --now shcripts-idle.timer
systemctl --user disable --now shcripts-idle.timer
```

Memory log tray icon (turn on "Start at login" in its menu to autostart):

```bash
scripts/memory/start-memlog-service.sh
```

## Configuration

Secrets and machine values (IPs, users, paths) go in `.env`, which is gitignored.

```bash
cp .env.example .env
```

`.env` has one `### global ###` section, then one `### <category> ###` section per `scripts/<category>/`, with vars named `<CATEGORY>_*`. The launcher loads `.env` for every script it runs. Scripts also source it themselves, so they work outside the launcher.

## Launcher

Scripts go in `scripts/<category>/`. The folder name is the category. `.sh` and `.py` files run in a new terminal. `.md` and `.txt` files open in your editor. The first header comment (`.sh`) or docstring line (`.py`) is shown as the description.

Keys: `r` run/open, `s` run with sudo, `e` edit, `t` terminal here, `l` latest log, `R` rescan, `q` quit.

## Hotkey

The launcher is a TUI, so it needs a terminal window. GNOME: Settings → Keyboard → Custom Shortcuts:

```text
Name:     shcripts
Command:  gnome-terminal -- python3 /home/dietcoke/shcripts/launcher/launcher.py
Shortcut: Super+B
```

## License

MIT
