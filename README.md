# shcripts

My scripts and system configs for one Linux laptop (Ubuntu, GNOME), with a terminal launcher to browse and run them.

What each script does: [GLOSSARY.md](GLOSSARY.md). Details live in each script's header.

Some scripts need system tools: `rclone` (syncdrive), `fzf` and `fd-find` plus `wl-clipboard` or `xclip` (fzf-copy), `notify-send` (memory warnings, idle reminder), `kitty` (tray report button, changeable in `.env`).

## Layout

```text
launcher/   the TUI launcher and setup.sh
scripts/    what the launcher lists, one folder per category
utils/      helpers the scripts call (not listed in the launcher)
logs/       per-run logs and the memory log (gitignored)
.env        your config (gitignored), see Configuration
```

## Setup

```bash
export SHCRIPTS_DIR="$HOME/shcripts"      # any location
git clone https://github.com/sushantpadha/shcripts "$SHCRIPTS_DIR"
bash "$SHCRIPTS_DIR/launcher/setup.sh"
"$SHCRIPTS_DIR/.venv/bin/python" "$SHCRIPTS_DIR/launcher/launcher.py"
```

`setup.sh` creates `.venv` with the Python deps, adds an app menu entry, and enables the idle reminder timer. Commands in this README use `$SHCRIPTS_DIR`: put the `export` line in `~/.bashrc`.

The scripts don't need it. When it's unset they work out the repo root from their own location. GNOME shortcuts, the app menu and systemd don't read `~/.bashrc`, so `setup.sh` writes the path into the files it generates.

Syncdrive also needs an rclone remote: run `rclone config` and name it to match `SYNC_REMOTE` in `.env`.

## Services

Idle reminder (a notification if the launcher hasn't been opened in 24 h, checked hourly):

```bash
systemctl --user enable --now shcripts-idle.timer
systemctl --user disable --now shcripts-idle.timer
```

Memory log tray icon (turn on "Start at login" in its menu to autostart):

```bash
"$SHCRIPTS_DIR/scripts/memory/start-memlog-service.sh"
```

## Configuration

Secrets, machine values (IPs, users, paths) and tunables go in `.env`, which is gitignored. `.env.example` lists every variable with a placeholder or default.

```bash
cp .env.example .env
```

`.env` has one `### global ###` section, then one `### <category> ###` section per `scripts/<category>/`, with vars named `<CATEGORY>_*`. The launcher loads `.env` for every script it runs. Scripts also source it themselves, so they work outside the launcher. Scripts fall back to a default when an optional variable is missing (e.g. `MEMORY_WARN_MB`, `APP_REMOTE_TMP`).

## Launcher

Scripts go in `scripts/<category>/`. The folder name is the category. `.sh` and `.py` files run in a new terminal. `.md` and `.txt` files open in your editor. The first header comment (`.sh`) or docstring line (`.py`) is shown as the description.

The right panel shows the script path, its description, the last 3 runs (time, duration, exit code) and the latest log path. Run history is kept in `.history.json`, logs in `logs/<category>/`. Both are gitignored.

Keys: `r` run/open, `s` run with sudo, `e` edit, `t` terminal here, `l` latest log, `R` rescan, `q` quit.

## Cleaning up

`scripts/maintenance/clean.sh` (also in the launcher) frees disk space. It offers `df` plus a disk usage explorer (ncdu, baobab or a plain `du` list), then goes through three sections. For each you pick `a` delete all, `s` select each group (default) or `n` skip:

- **shcripts files:** run logs, run history, idle marker, stale `/tmp` exit files, `__pycache__`, memory log, syncdrive history.
- **User caches:** thumbnails, pip, uv, npm, Go build, Trash, VS Code, Chrome, Spotify. Apps that may be running default to no.
- **System (sudo):** APT cache, unused packages, crash reports, old journal logs, old snap revisions.

In select mode each group is shown with its size and deleted only after you say yes. Delete all says yes to every group in the section, including the ones that default to no, and asks once more first, naming them. It never touches `.env`, `.venv`, your projects, or models and data in `~/.cache` (it lists the biggest folders there so you can decide). At the end it prints the free space gained on `/`.

## Hotkey

The launcher is a TUI, so it needs a terminal window. GNOME: Settings → Keyboard → Custom Shortcuts (the command runs without a shell, so write out the full path instead of `$SHCRIPTS_DIR`):

```text
Name:     shcripts
Command:  gnome-terminal -- <SHCRIPTS_DIR>/.venv/bin/python <SHCRIPTS_DIR>/launcher/launcher.py
Shortcut: Super+B
```

## License

MIT
