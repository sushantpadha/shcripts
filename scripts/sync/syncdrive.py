#!/usr/bin/env python3
"""Sync chosen local folders to Google Drive with rclone. Interactive, previews every change first.

Targets and the rclone remote live in the `### sync ###` section of the repo's .env:
    SYNC_REMOTE=drive-0
    SYNC_TARGET_1="name|/local/dir|remote/dir|*.md,*.pdf"
    SYNC_TARGET_2="name|/local/dir|remote/dir|@my.rclone-filter"
The last field is comma-separated globs, or @file for an rclone filter file inside the local dir.

`rclone sync` makes the remote match the local dir, so it DELETES remote files that are
gone locally. Every target shows uploads / changes / deletes and asks before syncing.

Setup: install rclone, run `rclone config`, name the remote to match SYNC_REMOTE.
State: ~/.syncdrive/state.json (last 3 syncs per target), ~/.syncdrive/.logs/ (SHA256 manifest per sync).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(os.environ.get("SHCRIPTS_DIR") or Path(__file__).resolve().parents[2])
load_dotenv(ROOT / ".env")

BASE_DIR = Path.home() / ".syncdrive"
STATE_PATH = BASE_DIR / "state.json"
LOG_DIR = BASE_DIR / ".logs"
KEEP = 3        # syncs remembered per target
PREVIEW = 20    # lines shown per preview section

RST, BOLD, DIM = "\033[0m", "\033[1m", "\033[2m"
RED, GRN, YLW, BLU, CYN = "\033[31m", "\033[32m", "\033[33m", "\033[34m", "\033[36m"


def c(text, color):
    return f"{color}{text}{RST}"


def hr():
    print(c("-" * 72, DIM))


def confirm(prompt, color=YLW):
    return input(c(prompt, color) + " [y/N]: ").strip().lower() in {"y", "yes"}


# ── config ──────────────────────────────────────────────────────────────────

def load_targets():
    remote = os.environ.get("SYNC_REMOTE")
    targets = []
    keys = [k for k in os.environ if k.startswith("SYNC_TARGET_")]
    for key in sorted(keys, key=lambda k: int(k.rsplit("_", 1)[1]) if k.rsplit("_", 1)[1].isdigit() else 0):
        parts = os.environ[key].split("|")
        if len(parts) != 4:
            sys.exit(c(f"{key} in .env needs 4 fields: name|local|remote|filter", RED))
        name, local, remote_path, flt = parts
        targets.append({"name": name, "local": local, "remote": f"{remote}:{remote_path}", "filter": flt})
    if not remote or not targets:
        sys.exit(c("No SYNC_REMOTE / SYNC_TARGET_* in .env. See the header of this script.", RED))
    return targets


def filter_args(t):
    """rclone args selecting which files of a target are synced."""
    if t["filter"].startswith("@"):
        path = Path(t["local"]) / t["filter"][1:]
        if not path.exists():
            raise FileNotFoundError(f"rclone filter file not found: {path}")
        return ["--filter-from", str(path)]
    return [a for g in t["filter"].split(",") if g.strip() for a in ("--include", g.strip())]


# ── state ───────────────────────────────────────────────────────────────────

def load_state():
    try:
        return json.loads(STATE_PATH.read_text())
    except FileNotFoundError:
        return {}


def record(t, manifest):
    """Save this sync's manifest, keep the last KEEP per target, prune older manifests."""
    now = datetime.now().isoformat(timespec="seconds")
    log = LOG_DIR / f"{t['name']}_{now.replace(':', '-')}.txt"
    log.write_text(manifest)

    state = load_state()
    history = [{"timestamp": now, "logfile": str(log)}] + state.get(t["name"], [])
    for old in history[KEEP:]:
        Path(old["logfile"]).unlink(missing_ok=True)   # our own manifests only
    state[t["name"]] = history[:KEEP]

    tmp = STATE_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(STATE_PATH)
    return log


# ── rclone ──────────────────────────────────────────────────────────────────

def preview(t):
    """Return {'+': uploads, '*': changed, '-': deletes} or None if the check failed."""
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "combined"
        r = subprocess.run(
            ["rclone", "check", t["local"], t["remote"], "--checksum", "--combined", str(out), *filter_args(t)],
            capture_output=True, text=True,
        )
        lines = out.read_text().splitlines() if out.exists() else []

    diff = {k: [l[2:] for l in lines if l.startswith(k + " ")] for k in "+*-!"}
    # rclone check exits 1 whenever anything differs, so only treat it as failed
    # if it produced no usable diff or hit read errors
    if diff["!"] or (r.returncode != 0 and not any(diff[k] for k in "+*-")):
        print(c("Preview failed:", RED))
        print("\n".join(r.stderr.strip().splitlines()[-5:]))
        for p in diff["!"][:PREVIEW]:
            print(f"  ! {p}")
        return None
    return diff


def show(diff):
    for key, label, color in (("+", "Upload", GRN), ("*", "Changed", YLW), ("-", "DELETE from remote", RED)):
        items = diff[key]
        if not items:
            continue
        print(c(f"\n{label}: {len(items)}", BOLD + color))
        for p in items[:PREVIEW]:
            print(f"  {c(key, color)} {p}")
        if len(items) > PREVIEW:
            print(c(f"  ... {len(items) - PREVIEW} more", DIM))


def run_sync(t):
    print(c(f"\n{'=' * 72}\n{t['name']}", BOLD + CYN) + f"  {t['local']} -> {t['remote']}")

    if not Path(t["local"]).is_dir():
        print(c("Local dir missing, skipped.", RED))
        return

    print(c("Checking what would change...", DIM))
    diff = preview(t)
    if diff is None:
        if not confirm("Sync anyway? (e.g. remote dir doesn't exist yet)", RED):
            return
    else:
        show(diff)
        if not any(diff[k] for k in "+*-"):
            print(c("Already in sync.", GRN))
            return
        ask = (f"\nSync now? {len(diff['-'])} remote files will be DELETED.", RED) if diff["-"] else ("\nSync now?", YLW)
        if not confirm(*ask):
            print(c("Skipped.", YLW))
            return

    print()
    r = subprocess.run(["rclone", "sync", t["local"], t["remote"], "--checksum",
                        "-v", "--stats-one-line", "--stats", "5s", *filter_args(t)])
    if r.returncode != 0:
        print(c(f"\n[x] Sync failed (rclone exit {r.returncode}). Nothing recorded. Rerun to retry.", RED))
        return

    h = subprocess.run(["rclone", "hashsum", "SHA256", t["local"], *filter_args(t)],
                       capture_output=True, text=True)
    manifest = h.stdout
    if h.returncode != 0:
        print(c(f"[!] Synced, but the manifest failed: {h.stderr.strip()[-200:]}", YLW))
    log = record(t, manifest)
    print(c(f"\n[+] Synced {t['name']}: {len(manifest.splitlines())} files. Manifest: {log}", GRN))


# ── ui ──────────────────────────────────────────────────────────────────────

def list_targets(targets):
    state = load_state()
    print(c("\nsyncdrive", BOLD + CYN))
    hr()
    for i, t in enumerate(targets, 1):
        last = state.get(t["name"], [{}])[0].get("timestamp", "never")
        print(f"{c(i, YLW)}  {c(t['name'], GRN):<20} {t['remote']:<24} {c('last: ' + last, DIM)}")
        print(c(f"   {t['local']}   [{t['filter']}]", DIM))
    hr()


def parse(inp, n):
    """'1 3' or '1-3' -> sorted valid indexes. Raises ValueError on junk."""
    picked = set()
    for part in inp.split():
        a, _, b = part.partition("-")
        picked.update(range(int(a), int(b or a) + 1))
    return sorted(i for i in picked if 1 <= i <= n)


def main():
    if not shutil.which("rclone"):
        sys.exit(c("rclone not installed.", RED))
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    targets = load_targets()

    while True:
        list_targets(targets)
        inp = input(c("Targets to sync (1 3, 1-3, h help, q quit): ", BOLD)).strip()
        if inp == "q":
            return
        if inp == "h":
            print(__doc__)
            continue
        try:
            picks = parse(inp, len(targets))
        except ValueError:
            picks = []
        if not picks:
            print(c("Nothing selected.", YLW))
            continue
        for i in picks:
            try:
                run_sync(targets[i - 1])
            except FileNotFoundError as e:
                print(c(str(e), RED))


if __name__ == "__main__":
    assert parse("1 3-4 9", 5) == [1, 3, 4], "parse self-check"
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\nBye.")
