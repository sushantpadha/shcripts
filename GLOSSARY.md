# Glossary

One line per script. Open the script itself for usage and details.

## launcher/

- `launcher.py`: the TUI. Lists everything under `scripts/`, runs scripts in a new terminal, opens notes in your editor, keeps the last 3 runs per script.
- `setup.sh`: creates `.venv` with the deps, adds the app menu entry, enables the idle reminder timer. Safe to rerun.

## scripts/desktop/

- `enabling-copyq.sh`: bind Super+V to the CopyQ clipboard menu in GNOME.
- `fzf-copy.sh`: fuzzy-pick a file under `~` and copy its full path to the clipboard.
- `green-adblock.sh`: start Spotify with the spotify-adblock library preloaded.

## scripts/app/ (Minecraft server)

- `backup_server.sh`: copy a world from the server to a local `.tar.gz`. Optional arg: world name (default `world`). Assumes the Paper/Spigot layout (`<world>`, `_nether`, `_the_end`); missing folders are skipped.
- `reset_server.sh`: restore a local backup onto the server, after you confirm the server is stopped. The current worlds are kept on the server as `<world>.bak-N.tgz`. Same Paper/Spigot layout assumption.

## scripts/maintenance/

- ⚠️ **`clean.sh` (BIG: deletes files on your whole system, not just the repo; built for this one machine).** Prints saved vs current system info and refuses on another machine. Read-only analysis (where the space is, folders to review by hand), an installed-software overview, then delete groups: shcripts files, user caches, leftovers and duplicates, system junk (APT, old kernels, journal keeping 7 days, rotated logs, old snaps). Every group shows its size first and asks before deleting, and `h` explains it; system steps need sudo. Never touches `.env`, projects, or models in `~/.cache`. `--refresh-header` saves this machine's info into `.env`.

## scripts/memory/

- `memlog.sh`: append one RAM, swap and memory-pressure snapshot to `logs/memlog.txt`. Pops up a warning when free RAM drops below `MEMORY_WARN_MB` (default 1500). The tray runs it every `MEMORY_INTERVAL_S` seconds (default 60).
- `memlog-report.sh`: summary of the memory log: lowest free RAM, peak swap, last snapshots before a reboot, OOM kills.
- `start-memlog-service.sh`: start the memory log tray icon.
- `setup-swap.sh`: one-time setup of an 8 GB `/swapfile` with an fstab entry. Needs sudo.

## scripts/nvidia/

- `psm.sh`: menu to switch the NVIDIA GPU between fully off and on-demand, or check its state (read-only, never wakes the GPU). Switching needs sudo and a reboot. Confirms first and backs up every file it touches to `/var/backups/psm/<time>/` with a `RESTORE.sh`.
- `doctor.sh`: read-only dump of GPU, driver, DKMS, Secure Boot and power state. Wakes the GPU (calls `nvidia-smi`), so use `psm.sh` status for a quiet check.
- `MEREAD.md`: notes on reading GPU power state, switching GPUs and recovering, including what `psm.sh` writes.

## scripts/power/

- `power-draw.sh`: live snapshot of battery draw, CPU clocks and temps, top processes, and whether the NVIDIA GPU is asleep. Read-only. Run with sudo for CPU package watts.

## scripts/sync/

- `syncdrive.py`: sync chosen local folders to Google Drive with rclone. Previews uploads and deletes before each sync. Targets are in `.env`.

## utils/app/

- `common.sh`: helpers shared by `scripts/app/*.sh` (loads `.env`, one reused ssh connection, failure report, free-space check). Sourced, not run.

## utils/maintenance/

- `analysis.sh`: read-only reports, detail texts and list builders for `clean.sh`. Sourced, not run.
- `software.sh`: the installed-software overview for `clean.sh`. Sourced, not run.
- `machine.sh`: the machine banner and check for `clean.sh`; saved info goes to `.env`. Sourced, not run.

## utils/memory/

- `memlog-tray.py`: tray icon to start or stop memory logging, show the report (in `MEMORY_TERMINAL`) and plots, and toggle autostart.
- `memlog-plot.py`: plot the memory log. Optional arg: hours to show.
