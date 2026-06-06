#!/usr/bin/env python3
# Interactive. Wrapper around rclone. Selective syncing to GDrive.

import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections import deque
from datetime import datetime
from pathlib import Path

DESCRIPTION = """
syncdrive.py

Interactive. Wrapper around rclone. Selective syncing to GDrive.
- One-shot manual syncs only
- Dry-run preview before syncing
- Last 3 sync histories retained
- Optional .gitignore / glob-pattern based filtering

Steps:
1. Install rclone and run `rclone config`
2. Set up remote for drive and ensure it matches `REMOTE_NAME`
3. Edit `TARGETS` in this script

Stored state:
  ~/.syncdrive/state.json : sync history metadata
  ~/.syncdrive/.logs/     : per-sync SHA256 manifests

Important:
- Remote deletions may occur because of `rclone sync`
- You will always be prompted before destructive actions.
"""

# ============================================================
# COLORS
# ============================================================

class C:
    RESET  = "\033[0m"

    BOLD   = "\033[1m"

    RED    = "\033[31m"
    GREEN  = "\033[32m"
    YELLOW = "\033[33m"
    BLUE   = "\033[34m"
    CYAN   = "\033[36m"

    DIM    = "\033[2m"


def color(text, c):
    return f"{c}{text}{C.RESET}"


def hr():
    print(color("-" * 72, C.DIM))


# ============================================================
# CONFIG
# ============================================================

DOC_PATTERN = ["*.md", "*.txt", "*.pdf", "*.html"]

REMOTE_NAME = "drive-0"

TARGETS = [
    {
        "keyword": "resume",
        "local_path": "/mnt/linuxdata/projects/Sushant_Resume",
        "remote_path": "Resumes",
        "patterns": DOC_PATTERN,
        "use_gitignore": False
    },

    {
        "keyword": "things",
        "local_path": "/mnt/linuxdata/things",
        "remote_path": "things",
        "patterns": DOC_PATTERN,
        "use_gitignore": False
    },
]

# ============================================================
# INTERNAL PATHS
# ============================================================

BASE_DIR = Path.home() / ".syncdrive"
STATE_PATH = BASE_DIR / "state.json"
LOG_DIR = BASE_DIR / ".logs"

# ============================================================
# UTILS
# ============================================================


def ensure_dirs():
    BASE_DIR.mkdir(exist_ok=True)
    LOG_DIR.mkdir(exist_ok=True)

    if not STATE_PATH.exists():
        with open(STATE_PATH, "w") as f:
            json.dump({}, f, indent=2)


def load_state():
    with open(STATE_PATH) as f:
        return json.load(f)


def save_state(state):
    tmp = STATE_PATH.with_suffix(".tmp")

    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)

    shutil.move(tmp, STATE_PATH)


def sha256(path):
    h = hashlib.sha256()

    with open(path, "rb") as f:
        while chunk := f.read(1024 * 1024):
            h.update(chunk)

    return h.hexdigest()


def confirm(prompt):
    ans = input(
        color(prompt, C.YELLOW) +
        " [y/N]: "
    ).strip().lower()

    return ans in {"y", "yes"}


def print_banner():
    print()

    print(color("syncdrive", C.BOLD + C.CYAN))
    print(color("=" * 72, C.DIM))

    print(
        color("Remote", C.BLUE) +
        f": {REMOTE_NAME}"
    )

    print()


def print_help():
    print(DESCRIPTION.strip())
    print()
    print_banner()

    print(color("Configured mappings", C.BOLD))
    hr()

    print(
        f"{color('ID', C.BOLD):<4} "
        f"{color('KEYWORD', C.BOLD):<16} "
        f"{color('REMOTE', C.BOLD)}"
    )

    hr()

    for i, t in enumerate(TARGETS, start=1):
        remote = f"{REMOTE_NAME}:{t['remote_path']}"

        print(
            f"{color(str(i), C.YELLOW):<4} "
            f"{color(t['keyword'], C.GREEN):<16} "
            f"{remote}"
        )

        print(
            f"    local      : {t['local_path']}"
        )

        print(
            f"    patterns   : "
            f"{', '.join(t['patterns'])}"
        )

        print(
            f"    gitignore  : "
            f"{t['use_gitignore']}"
        )

        print()

    print(color("Interactive commands", C.BOLD))
    hr()

    print("  h       -> show help")
    print("  q       -> quit")
    print("  1 2     -> sync selected targets")
    print("  1-3     -> sync range")

    print()

    state = load_state()

    print(color("Last sync history", C.BOLD))
    hr()

    if not state:
        print(color("No syncs recorded.", C.BLUE))
        print()
        return

    for keyword, history in state.items():
        print(color(keyword, C.GREEN))

        for entry in history:
            print(
                f"  {entry['timestamp']}"
            )

            print(
                f"    log: {entry['logfile']}"
            )

        print()


def build_rclone_command(target):
    cmd = [
        "rclone",
        "sync",
        target["local_path"],
        f"{REMOTE_NAME}:{target['remote_path']}",
        "--checksum",
        "--stats-one-line",
        "--stats=100ms"
    ]

    for p in target["patterns"]:
        cmd.extend(["--include", p.strip()])

    if target.get("use_gitignore", False):
        gitignore = os.path.join(
            target["local_path"],
            ".gitignore"
        )

        if os.path.exists(gitignore):
            cmd.extend(["--filter-from", gitignore])

    return cmd

def collect_files(target):
    root = Path(target["local_path"])

    if not root.exists():
        return []

    matched = []

    for pattern in target["patterns"]:
        matched.extend([
            p for p in root.rglob("*")
            if p.is_file() and p.match(pattern)
        ])

    return sorted(set(matched))


def make_log(target, files):
    now = datetime.now().isoformat(timespec="seconds")

    entries = []

    for f in files:
        rel = os.path.relpath(
            f,
            target["local_path"]
        )

        try:
            checksum = sha256(f)

        except Exception as e:
            checksum = f"ERROR: {e}"

        entries.append({
            "path": rel,
            "sha256": checksum
        })

    payload = {
        "timestamp": now,
        "keyword": target["keyword"],
        "local_path": target["local_path"],
        "remote_path": target["remote_path"],
        "files": entries
    }

    logfile = LOG_DIR / (
        f"{target['keyword']}_"
        f"{now.replace(':', '-')}.json"
    )

    with open(logfile, "w") as f:
        json.dump(payload, f, indent=2)

    return now, str(logfile)


def update_state(keyword, timestamp, logfile):
    state = load_state()

    history = deque(
        state.get(keyword, []),
        maxlen=3
    )

    history.appendleft({
        "timestamp": timestamp,
        "logfile": logfile
    })

    state[keyword] = list(history)

    save_state(state)


def parse_selection(inp):
    selected = set()

    for part in inp.split():
        if "-" in part:
            a, b = map(int, part.split("-"))
            selected.update(range(a, b + 1))
        else:
            selected.add(int(part))

    return sorted([
        x for x in selected
        if 1 <= x <= len(TARGETS)
    ])


def print_targets():
    hr()

    print(
        f"{color('ID', C.BOLD):<4}"
        f"{color('KEYWORD', C.BOLD):<16}"
        f"{color('REMOTE', C.BOLD)}"
    )

    hr()

    for i, t in enumerate(TARGETS, start=1):
        remote = (
            f"{REMOTE_NAME}:"
            f"{t['remote_path']}"
        )

        print(
            f"{color(str(i), C.YELLOW):<4}"
            f"{color(t['keyword'], C.GREEN):<16}"
            f"{remote}"
        )

    print()

def read_lines(path):
    if not os.path.exists(path):
        return []

    with open(path) as f:
        return [
            line.strip()
            for line in f
            if line.strip()
        ]


def preview_changes(target):
    uploads_file = "/tmp/rclone_uploads.txt"
    deletes_file = "/tmp/rclone_deletes.txt"
    differ_file = "/tmp/rclone_differ.txt"

    for f in [
        uploads_file,
        deletes_file,
        differ_file
    ]:
        try:
            os.remove(f)
        except FileNotFoundError:
            pass

    cmd = [
        "rclone",
        "check",
        target["local_path"],
        f"{REMOTE_NAME}:{target['remote_path']}",
        "--one-way",
        "--checksum",
        "--missing-on-dst", uploads_file,
        "--missing-on-src", deletes_file,
        "--differ", differ_file
    ]

    for p in target["patterns"]:
        cmd.extend(["--include", p.strip()])

    if target.get("use_gitignore", False):
        gitignore = os.path.join(
            target["local_path"],
            ".gitignore"
        )

        if os.path.exists(gitignore):
            cmd.extend(["--filter-from", gitignore])

    subprocess.run(
        cmd,
        capture_output=True,
        text=True
    )

    uploads = read_lines(uploads_file)
    modifies = read_lines(differ_file)
    deletes = read_lines(deletes_file)

    print()

    if uploads:
        print(color("Uploads", C.GREEN))
        hr()

        for x in uploads:
            print(f"  {x}")

        print()

    if modifies:
        print(color("Modified", C.YELLOW))
        hr()

        for x in modifies:
            print(f"  {x}")

        print()

    if deletes:
        print(color("Deletes", C.RED))
        hr()

        for x in deletes:
            print(f"  {x}")

        print()

    if not uploads and not modifies and not deletes:
        print(color("No changes.", C.BLUE))
        print()

    return uploads, modifies, deletes


def run_sync(target):
    print()

    print(color("=" * 72, C.DIM))

    print(
        color("SYNCING", C.BOLD + C.CYAN) +
        f": {color(target['keyword'], C.GREEN)}"
    )

    print(color("=" * 72, C.DIM))

    local = Path(target["local_path"])

    if not local.exists():
        print()
        print(
            color(
                "[!] Local path missing.",
                C.RED
            )
        )

        return

    files = collect_files(target)

    print()

    print(
        f"{color('Files considered', C.BLUE)}"
        f": {len(files)}"
    )

    timestamp, logfile = make_log(
        target,
        files
    )

    print()
    print(
        color(
            "Generating preview...",
            C.CYAN
        )
    )

    uploads, modifies, deletes = preview_changes(target)

    if not confirm(
        "Potential deletions detected. Continue?" if deletes else "Continue?"
    ):
        print(
            color("Skipped.", C.YELLOW)
        )

        return

    print()

    print(
        color(
            "Running actual sync...",
            C.CYAN
        )
    )

    print()

    real_cmd = build_rclone_command(target)
    
    result = subprocess.run(
        real_cmd,
        capture_output=True,
        text=True
    )

    output = (
        result.stdout +
        "\n" +
        result.stderr
    )

    print(output)

    if result.returncode != 0:
        print(
            color(
                "[!] Sync failed.",
                C.RED
            )
        )

        return

    update_state(
        target["keyword"],
        timestamp,
        logfile
    )

    print()

    print(color("Summary", C.BOLD))
    hr()

    print(
        f"{color('Keyword', C.BLUE):<14}"
        f"{target['keyword']}"
    )

    print(
        f"{color('Files', C.BLUE):<14}"
        f"{len(files)}"
    )

    print(
        f"{color('Log', C.BLUE):<14}"
        f"{logfile}"
    )

    print()

    print(
        color(
            "[+] Sync complete.",
            C.GREEN
        )
    )


def repl():
    print_banner()

    while True:
        print_targets()

        cmd = input(
            color(
                "Select targets "
                "(h for help, q to quit): ",
                C.BOLD
            )
        ).strip()

        if not cmd:
            continue

        if cmd == "q":
            print("Bye.")
            return

        if cmd == "h":
            print_help()
            continue

        try:
            picks = parse_selection(cmd)

        except Exception:
            print(
                color(
                    "Invalid selection.",
                    C.RED
                )
            )

            continue

        if not picks:
            print(
                color(
                    "Nothing selected.",
                    C.YELLOW
                )
            )

            continue

        selected = [
            TARGETS[i - 1]
            for i in picks
        ]

        print()

        print(
            color(
                "Planned operations",
                C.BOLD
            )
        )

        hr()

        for t in selected:
            print(
                f"{color(t['keyword'], C.GREEN):<16}"
                f"{t['local_path']}"
            )

            print(
                f"{'':<16}"
                f"-> "
                f"{REMOTE_NAME}:{t['remote_path']}"
            )

            print()

        if not confirm("Continue?"):
            print(
                color(
                    "Aborted.",
                    C.YELLOW
                )
            )

            continue

        for target in selected:
            run_sync(target)


def main():
    ensure_dirs()

    if len(sys.argv) > 1:
        arg = sys.argv[1]

        if arg in {"-h", "--help"}:
            print_help()
            return

    repl()


if __name__ == "__main__":
    main()
