# Glossary

One line per script. Open the script itself for usage and details.

## scripts/

- `syncdrive.py`: sync chosen local folders to Google Drive with rclone. Interactive, shows a dry run first.
- `enabling-copyq.sh`: bind Super+V to the CopyQ clipboard menu in GNOME.
- `fzf-copy.sh`: fuzzy-pick a file and copy its full path to the clipboard.
- `green-adblock.sh`: start Spotify with the spotify-adblock library preloaded.

## scripts/app/ (Minecraft server)

- `backup_server.sh`: copy a world from the server to a local `.tar.gz`. Optional arg: world name (default `world`).
- `reset_server.sh`: restore a local backup onto the server. The current world is kept on the server as `<world>.bak-N.tgz`.

## scripts/memory/

- `memlog.sh`: append one RAM, swap and memory-pressure snapshot to `logs/memlog.txt`. Warns when free RAM drops below 1500 MB. The tray runs it every minute.
- `memlog-report.sh`: summary of the memory log: lowest free RAM, peak swap, last snapshots before a reboot, OOM kills.
- `start-memlog-service.sh`: start the memory log tray icon.
- `setup-swap.sh`: one-time setup of an 8 GB `/swapfile` with an fstab entry. Needs sudo.

## scripts/nvidia/

- `psm.sh`: turn the NVIDIA GPU off with GRUB kernel args, or set it back to on-demand. Needs sudo and a reboot.
- `doctor.sh`: read-only dump of GPU, driver and power state.
- `MEREAD.md`: notes on reading GPU power state and switching GPUs.

## scripts/power/

- `find-power-draw.md`: cheat sheet for finding what drains battery or heats the laptop.

## utils/memory/

- `memlog-tray.py`: tray icon to start or stop memory logging, show the report and plots, and toggle autostart.
- `memlog-plot.py`: plot the memory log. Optional arg: hours to show.
