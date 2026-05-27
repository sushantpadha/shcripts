#!/usr/bin/env python3
"""
shcripts — TUI launcher
═══════════════════════
Navigate with arrows, run scripts in a disowned terminal, open notes in editor.

Supported:
    .sh   -> runnable scripts
    .txt  -> notes / cheatsheets
    .md   -> markdown notes / cheatsheets

Usage:
    python3 launcher.py
    python3 launcher.py --check-idle
"""

import sys, os, json, subprocess, shutil, time
from pathlib import Path
from datetime import datetime, timedelta
from dataclasses import dataclass, asdict

from textual.app import App, ComposeResult
from textual.widgets import Header, Footer, Tree, Label, Static
from textual.widgets.tree import TreeNode
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive


# ── Config ───────────────────────────────────────────────────────────────────

SHCRIPTS_DIR  = Path.home() / "shcripts"
SCRIPTS_DIR   = SHCRIPTS_DIR / "scripts"
LOGS_DIR      = SHCRIPTS_DIR / "logs"
HISTORY_FILE  = SHCRIPTS_DIR / ".history.json"
LASTOPEN_FILE = SHCRIPTS_DIR / ".lastopen"
MAX_HISTORY   = 3


# ── Editor / terminal detection ──────────────────────────────────────────────

def find_editor() -> str:
    for env in ["VISUAL", "EDITOR"]:
        val = os.environ.get(env, "")
        if val and shutil.which(val.split()[0]):
            return val.split()[0]

    for e in [
        "code",
        "gedit",
        "kate",
        "geany",
        "mousepad",
        "nano",
        "vim",
        "vi",
    ]:
        if shutil.which(e):
            return e

    return "xdg-open"


def find_terminal() -> list[str] | None:
    candidates = [
        ("gnome-terminal", ["gnome-terminal", "--"]),
        ("konsole",        ["konsole", "-e"]),
        ("xfce4-terminal", ["xfce4-terminal", "-e"]),
        ("xterm",          ["xterm", "-e"]),
        ("alacritty",      ["alacritty", "-e"]),
        ("kitty",          ["kitty"]),
    ]

    for name, prefix in candidates:
        if shutil.which(name):
            return prefix

    return None


EDITOR       = find_editor()
TERMINAL_CMD = find_terminal()


# ── Data ─────────────────────────────────────────────────────────────────────

@dataclass
class ScriptRun:
    ts: str
    exit_code: int
    duration: float
    log_file: str

    def to_dict(self):
        return asdict(self)

    @staticmethod
    def from_dict(d):
        return ScriptRun(**d)


@dataclass
class ScriptMeta:
    name: str
    path: str
    category: str
    description: str
    usage: str
    author: str
    created: str
    last_modified: str
    kind: str   # "script" | "text"


# ── Header parsing ───────────────────────────────────────────────────────────

def parse_header(path: str) -> dict:
    meta = {
        "description": "",
        "usage": "",
        "author": "",
        "created": "",
        "last_modified": "",
    }

    try:
        with open(path) as f:
            lines = f.readlines()

        in_block = False

        for line in lines:
            line = line.rstrip()

            if "################################" in line:
                in_block = not in_block
                continue

            if in_block:
                for key, field in [
                    ("# Description:",   "description"),
                    ("# USAGE:",         "usage"),
                    ("# Author:",        "author"),
                    ("# Created:",       "created"),
                    ("# Last Modified:", "last_modified"),
                ]:
                    if line.startswith(key):
                        meta[field] = line.replace(key, "").strip()

    except Exception:
        pass

    return meta


# ── History ──────────────────────────────────────────────────────────────────

def load_history() -> dict:
    if HISTORY_FILE.exists():
        try:
            raw = json.loads(HISTORY_FILE.read_text())
            return {
                k: [ScriptRun.from_dict(r) for r in v]
                for k, v in raw.items()
            }
        except Exception:
            pass

    return {}


def save_history(history: dict):
    SHCRIPTS_DIR.mkdir(parents=True, exist_ok=True)

    HISTORY_FILE.write_text(
        json.dumps(
            {
                k: [r.to_dict() for r in v]
                for k, v in history.items()
            },
            indent=2,
        )
    )


def record_run(history: dict, path: str,
               exit_code: int, duration: float, log: str):

    run = ScriptRun(
        datetime.now().isoformat(timespec="seconds"),
        exit_code,
        round(duration, 2),
        log,
    )

    history.setdefault(path, []).insert(0, run)
    history[path] = history[path][:MAX_HISTORY]

    save_history(history)


# ── Idle ─────────────────────────────────────────────────────────────────────

def touch_lastopen():
    LASTOPEN_FILE.write_text(datetime.now().isoformat())


def check_idle_notify():
    if not LASTOPEN_FILE.exists():
        return

    try:
        last = datetime.fromisoformat(
            LASTOPEN_FILE.read_text().strip()
        )

        if datetime.now() - last >= timedelta(hours=24):
            subprocess.Popen(
                [
                    "notify-send",
                    "-u", "normal",
                    "-a", "shcripts",
                    "shcripts",
                    "You haven't checked your scripts in 24+ hours",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    except Exception:
        pass


# ── Scanner ──────────────────────────────────────────────────────────────────

def scan() -> dict[str, list[ScriptMeta]]:
    SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)

    result: dict[str, list[ScriptMeta]] = {}

    exts = {
        ".sh":  "script",
        ".txt": "text",
        ".md":  "text",
    }

    for p in sorted(SCRIPTS_DIR.rglob("*")):
        if not p.is_file():
            continue

        kind = exts.get(p.suffix.lower())

        if not kind:
            continue

        cat = (
            p.parent.name
            if p.parent.name != "scripts"
            else "uncategorized"
        )

        if kind == "script":
            m = parse_header(str(p))
        else:
            m = {
                "description": "",
                "usage": "",
                "author": "",
                "created": "",
                "last_modified": "",
            }

        result.setdefault(cat, []).append(
            ScriptMeta(
                name=p.stem,
                path=str(p),
                category=cat,
                description=m["description"],
                usage=m["usage"],
                author=m["author"],
                created=m["created"],
                last_modified=m["last_modified"],
                kind=kind,
            )
        )

    return result


# ── Helpers ──────────────────────────────────────────────────────────────────

def open_terminal_in_dir(path: str):
    if not TERMINAL_CMD:
        return "no terminal found"

    directory = str(Path(path).parent)

    subprocess.Popen(
        TERMINAL_CMD,
        cwd=directory,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    return None


def open_in_editor(path: str):
    subprocess.Popen(
        [EDITOR, path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def run_in_terminal(script: ScriptMeta,
                    history: dict,
                    sudo: bool = False):

    if not TERMINAL_CMD:
        return "no terminal found"

    log_dir = LOGS_DIR / script.category
    log_dir.mkdir(parents=True, exist_ok=True)

    ts       = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    log_file = log_dir / f"{script.name}-{ts}.log"

    tmp_exit = Path(
        f"/tmp/shcripts_{script.name}_{int(time.time())}.exit"
    )

    start = time.time()

    cmd = (
        f"exec > >(tee {log_file}); "
        f"exec 2>&1; "
        f"echo ''; "
        f"echo '  ▶  {script.name}"
        f"{' [sudo]' if sudo else ''}'; "
        f"echo ''; "
        f"{'sudo ' if sudo else ''}"
        f"bash {script.path!r}; "
        f"CODE=$?; "
        f"echo $CODE > {tmp_exit}; "
        f"echo ''; "
        f"[ $CODE -eq 0 ] "
        f"&& echo '  ✓  exit 0' "
        f"|| echo \"  ✗  exit $CODE\"; "
        f"echo ''; "
        f"echo 'Press Enter to close...'; "
        f"read"
    )

    proc = subprocess.Popen(
        TERMINAL_CMD + ["bash", "-c", cmd],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    def _wait():
        proc.wait()

        exit_code = -1

        try:
            if tmp_exit.exists():
                exit_code = int(
                    tmp_exit.read_text().strip()
                )
                tmp_exit.unlink()

        except Exception:
            pass

        record_run(
            history,
            script.path,
            exit_code,
            time.time() - start,
            str(log_file),
        )

    import threading

    threading.Thread(target=_wait, daemon=True).start()

    return None


# ── UI ───────────────────────────────────────────────────────────────────────

CSS = """
Screen {
    background: #0a0c12;
}

#sidebar {
    width: 50%;
    border-right: solid #1e2130;
    padding: 0 1;
}

#detail {
    width: 50%;
    padding: 1 2;
}

Tree {
    background: #0a0c12;
    color: #c8cfe8;
}

Tree > .tree--guides {
    color: #1e2130;
}

Tree > .tree--cursor {
    background: #181c27;
    color: #8be9fd;
}

#detail-title {
    color: #8be9fd;
    text-style: bold;
    margin-bottom: 1;
}

#detail-body {
    color: #c8cfe8;
}

#status-bar {
    background: #0a0c12;
    border-top: solid #1e2130;
    height: 1;
    padding: 0 1;
    color: #2e3450;
}

#status-bar.running {
    color: #818cf8;
}

#status-bar.success {
    color: #4ade80;
}

#status-bar.error {
    color: #f87171;
}
"""


class ShcriptsTUI(App):

    CSS = CSS

    BINDINGS = [
        Binding("r",      "run",       "Run/Open", show=True),
        Binding("s",      "run_sudo",  "Run sudo", show=True),
        Binding("e",      "edit",      "Edit",     show=True),
        Binding("t",      "terminal",  "Terminal", show=True),
        Binding("l",      "logs",      "Logs",     show=True),
        Binding("R",      "rescan",    "Rescan",   show=True),
        Binding("q",      "quit",      "Quit",     show=True),
        Binding("escape", "quit",      "Quit",     show=False),
        Binding("enter",  "run",       "Run",      show=False),
    ]

    status_text = reactive("ready")
    status_cls  = reactive("idle")

    def __init__(self):
        super().__init__()

        self.history        = load_history()
        self.scripts_by_cat = scan()
        self._selected: ScriptMeta | None = None


    # ── Layout ───────────────────────────────────────────────────────────────

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)

        with Horizontal():

            with Vertical(id="sidebar"):
                yield Tree("📁 shcripts", id="tree")

            with Vertical(id="detail"):
                yield Label("", id="detail-title")
                yield Static("", id="detail-body")

        yield Static(id="status-bar")
        yield Footer()


    def on_mount(self):
        touch_lastopen()

        self._build_tree()
        self._update_status("ready", "idle")

        self.query_one("#tree").focus()


    # ── Tree ─────────────────────────────────────────────────────────────────

    def _build_tree(self):
        tree: Tree = self.query_one("#tree")

        tree.clear()

        root = tree.root
        root.expand()

        if not self.scripts_by_cat:
            root.add_leaf(
                "(no files found — add .sh/.txt/.md files)"
            )
            return

        for cat in sorted(self.scripts_by_cat.keys()):

            cat_node = root.add(
                f"[bold cyan]📁 {cat}[/]"
            )

            for script in self.scripts_by_cat[cat]:

                runs = self.history.get(script.path, [])
                dots = self._dots(runs)

                icon = (
                    "⚙"
                    if script.kind == "script"
                    else "📄"
                )

                label = (
                    f"{icon} "
                    f"{script.name} "
                    f"[dim]{dots}[/]"
                )

                leaf = cat_node.add_leaf(label)
                leaf.data = script

            cat_node.expand()


    def _dots(self, runs: list[ScriptRun]) -> str:
        if not runs:
            return "· · ·"

        symbols = []

        for r in runs[:MAX_HISTORY]:
            symbols.append(
                "●" if r.exit_code == 0 else "○"
            )

        return " ".join(symbols)


    # ── Selection ────────────────────────────────────────────────────────────

    def on_tree_node_highlighted(
        self,
        event: Tree.NodeHighlighted,
    ):
        node: TreeNode = event.node

        script = (
            node.data
            if hasattr(node, "data")
            else None
        )

        self._selected = script
        self._refresh_detail(script)


    def _refresh_detail(self,
                        script: ScriptMeta | None):

        title = self.query_one(
            "#detail-title",
            Label,
        )

        body = self.query_one(
            "#detail-body",
            Static,
        )

        if not script:
            title.update("")
            body.update("")
            return

        title.update(script.name)

        runs = self.history.get(script.path, [])

        lines = []

        if script.description:
            lines.append(
                f"[dim]desc   [/]  "
                f"{script.description}"
            )

        if script.usage:
            lines.append(
                f"[dim]usage  [/]  "
                f"{script.usage}"
            )

        lines.append(
            f"[dim]type   [/]  {script.kind}"
        )

        lines.append("")
        lines.append(
            f"[dim]path   [/]  "
            f"[dim]{script.path}[/]"
        )

        lines.append(
            f"[dim]editor [/]  {EDITOR}"
        )

        lines.append(
            f"[dim]term   [/]  "
            f"{TERMINAL_CMD[0] if TERMINAL_CMD else 'none'}"
        )

        lines.append("")

        if runs:
            lines.append(
                "[dim]─── last runs ───[/]"
            )

            for r in runs:

                ts = r.ts.replace("T", " ")

                icon = (
                    "[green]✓[/]"
                    if r.exit_code == 0
                    else "[red]✗[/]"
                )

                lines.append(
                    f"  {icon}  "
                    f"{ts}  "
                    f"{r.duration:.1f}s  "
                    f"[dim]{r.log_file}[/]"
                )

        elif script.kind == "script":
            lines.append("[dim]no runs yet[/]")

        lines.append("")

        lines.append(
            "[dim]r[/] run/open   "
            "[dim]s[/] sudo   "
            "[dim]e[/] edit   "
            "[dim]t[/] terminal   "
            "[dim]l[/] logs   "
            "[dim]R[/] rescan"
        )

        body.update("\n".join(lines))


    # ── Actions ──────────────────────────────────────────────────────────────
    def action_terminal(self):
        s = self._selected

        if not s:
            self._update_status(
                "select a file first",
                "error",
            )
            return

        err = open_terminal_in_dir(s.path)

        if err:
            self._update_status(
                f"✗ {err}",
                "error",
            )
            return

        self._update_status(
            f"🖥 opened terminal in {Path(s.path).parent}",
            "idle",
        )

    def action_run(self):
        s = self._selected

        if not s:
            self._update_status(
                "select a file first",
                "error",
            )
            return

        if s.kind == "text":
            open_in_editor(s.path)

            self._update_status(
                f"📄 opened {s.name} in {EDITOR}",
                "idle",
            )

            return

        err = run_in_terminal(s, self.history)

        if err:
            self._update_status(
                f"✗ {err}",
                "error",
            )

        else:
            self._update_status(
                f"▶ launched {s.name}",
                "running",
            )

            self.set_timer(
                2.0,
                lambda: self._refresh_detail(
                    self._selected
                ),
            )


    def action_run_sudo(self):
        s = self._selected

        if not s:
            self._update_status(
                "select a script first",
                "error",
            )
            return

        if s.kind != "script":
            self._update_status(
                "sudo only applies to scripts",
                "error",
            )
            return

        err = run_in_terminal(
            s,
            self.history,
            sudo=True,
        )

        if err:
            self._update_status(
                f"✗ {err}",
                "error",
            )

        else:
            self._update_status(
                f"▶ launched {s.name} as sudo",
                "running",
            )

            self.set_timer(
                2.0,
                lambda: self._refresh_detail(
                    self._selected
                ),
            )


    def action_edit(self):
        s = self._selected

        if not s:
            self._update_status(
                "select a file first",
                "error",
            )
            return

        open_in_editor(s.path)

        self._update_status(
            f"✎ opened {s.name} in {EDITOR}",
            "idle",
        )


    def action_logs(self):
        s = self._selected

        if not s:
            self._update_status(
                "select a script first",
                "error",
            )
            return

        if s.kind != "script":
            self._update_status(
                "text files do not have logs",
                "error",
            )
            return

        runs = self.history.get(s.path, [])

        if not runs:
            self._update_status(
                f"no logs for {s.name}",
                "error",
            )
            return

        log = Path(runs[0].log_file)

        if not log.exists():
            self._update_status(
                f"log missing: {log}",
                "error",
            )
            return

        open_in_editor(str(log))

        self._update_status(
            f"📄 opened latest log",
            "idle",
        )


    def action_rescan(self):
        self.scripts_by_cat = scan()
        self.history        = load_history()

        self._build_tree()

        total = sum(
            len(v)
            for v in self.scripts_by_cat.values()
        )

        self._update_status(
            f"rescanned — {total} files",
            "idle",
        )


    def action_quit(self):
        self.exit()


    # ── Status ───────────────────────────────────────────────────────────────

    def _update_status(self,
                       text: str,
                       cls: str = "idle"):

        bar = self.query_one(
            "#status-bar",
            Static,
        )

        bar.update(f" {text}")

        bar.remove_class(
            "idle",
            "running",
            "success",
            "error",
        )

        bar.add_class(cls)


# ── Entry ────────────────────────────────────────────────────────────────────

def main():

    for d in [
        SHCRIPTS_DIR,
        SCRIPTS_DIR,
        LOGS_DIR,
    ]:
        d.mkdir(parents=True, exist_ok=True)

    existing = any(
        p.suffix in [".sh", ".txt", ".md"]
        for p in SCRIPTS_DIR.rglob("*")
    )

    if not existing:

        example_dir = SCRIPTS_DIR / "examples"
        example_dir.mkdir(exist_ok=True)

        sample = example_dir / "hello.sh"

        sample.write_text(
            "#!/usr/bin/env bash\n"
            "echo 'Hello from shcripts!'\n"
            "sleep 1\n"
            "echo 'Done!'\n"
        )

        sample.chmod(0o755)

        notes = example_dir / "linux-cheatsheet.md"

        notes.write_text(
            "# Linux Cheatsheet\n\n"
            "## Disk usage\n"
            "`du -sh *`\n\n"
            "## Find large files\n"
            "`find . -type f | xargs du -h | sort -h`\n"
        )

    if "--check-idle" in sys.argv:
        check_idle_notify()
        sys.exit(0)

    app = ShcriptsTUI()
    app.run()


if __name__ == "__main__":
    main()