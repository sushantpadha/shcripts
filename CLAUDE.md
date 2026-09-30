# shcripts

Personal toolbox for one Linux laptop (Ubuntu, GNOME). Small runnable scripts, script collections, and system configs, run from a TUI launcher (`launcher/launcher.py`).

## Layout

- `scripts/<category>/`: what the launcher lists. Folder name = category. `.sh` and `.py` run, `.md` and `.txt` open in an editor.
- `utils/`: helpers the scripts call. Not listed in the launcher.
- `logs/`: per-run logs. Gitignored.
- `scripts/maintenance/clean.sh` checks the saved system info of this machine (`MAINTENANCE_MACHINE_*` in `.env`) and refuses to run elsewhere. After ANY edit to it or to `utils/maintenance/*.sh`, run `bash scripts/maintenance/clean.sh --refresh-header` and mention it in the commit. Its helpers live in `utils/maintenance/`. It cleans generated files (`logs/`, `.history.json`, `.lastopen`, `~/.syncdrive`), safe caches and system junk. A new generated file or directory means adding it to that script. Only add caches that apps rebuild; never data or models.
- Repo root: `$SHCRIPTS_DIR` if set, else derived from the script location. Never hardcode `~/shcripts`.
- Python: `.venv` (made by `launcher/setup.sh`). Child Python scripts run with the launcher's interpreter.
- `.env`: secrets and machine config (IPs, users, paths). Gitignored. Update `.env.example` whenever you add a var. See the README for the section format.

## Rules

- Secrets and machine-specific values go in `.env`, never in scripts. Tunables too (thresholds, intervals, process or terminal names): read them from `.env` with a default in the script.
- Keep scripts small and simple. Prefer interactive (run it, then pick from menus or prompts) over flags and arguments, unless arguments clearly fit better.
- Print readable, colored output unless told otherwise.
- Never do anything destructive (delete, overwrite, reformat, touch `/etc`, remote `rm`) without saying so first. Scripts must confirm before destructive steps.
- Code: caveman + ponytail skills. Shortest working version, stdlib first, no speculative features.
- Docs: plain-docs + caveman skills. Short, direct, concrete.

## Docs split

- `GLOSSARY.md`: one line per script, what it does. General info only.
- The script's own header comment or docstring: details, usage, caveats. The first line doubles as the launcher description.

Adding or removing a script means updating `GLOSSARY.md`. If a script can't be described in one short line, it probably needs trimming or splitting. Ask the user.
