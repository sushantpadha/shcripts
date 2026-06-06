#!/usr/bin/env python3
# FAILS on free plan; better to manually export+save; # backup full notion workspace; upto 3 rolling; uses env vars for token and backup dir

"""
notion_backup.py: Downloads your full Notion workspace as a zip,
keeping 3 rolling backups in a specified folder.

Usage:
  python notion_backup.py

Config via environment variables (or edit the CONFIG block below):
  NOTION_TOKEN_V2   — your token_v2 cookie value
  NOTION_FILE_TOKEN — your file_token cookie value
  NOTION_SPACE_ID   — your workspace space ID (optional but recommended)
  NOTION_BACKUP_DIR — directory to save backups (default: ~/notion-backups)
"""

import os
import sys
import time
import requests
from datetime import datetime
from pathlib import Path
from dotenv import load_dotenv

# Standalone fallback — load_dotenv won't overwrite vars already set by launcher
_env = Path(__file__).resolve().parents[1] / ".env"  # scripts/ -> shcripts/
load_dotenv(_env)

# ── CONFIG (override with env vars or edit here) ──────────────────────────────

TOKEN_V2 = os.environ.get("NOTION_TOKEN_V2", "")
FILE_TOKEN = os.environ.get("NOTION_FILE_TOKEN", "")
SPACE_ID = os.environ.get(
    "NOTION_SPACE_ID", ""
)  # pin explicitly; derived at runtime if unset
BACKUP_DIR = Path(os.environ.get("NOTION_BACKUP_DIR", Path.home() / "notion-backups"))
KEEP_N = 3  # number of rolling backups to keep
EXPORT_TYPE = "markdown"  # "markdown" or "html" or "pdf"
INCLUDE_SUBDBS = True  # include sub-databases in export
POLL_INTERVAL = 5  # seconds between status checks
MAX_WAIT = 600  # max seconds to wait for export to be ready

# ─────────────────────────────────────────────────────────────────────────────

BASE_URL = "https://www.notion.so/api/v3"

HEADERS = {
    "Content-Type": "application/json",
    "Cookie": f"token_v2={TOKEN_V2}; file_token={FILE_TOKEN}",
    "Notion-Client-Version": "23.13.0.324",
}


def log(msg: str):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}")


def get_user_content() -> dict:
    """Fetch workspace/space info to get the space ID."""
    r = requests.post(
        f"{BASE_URL}/loadUserContent",
        headers=HEADERS,
        json={},
        timeout=30,
    )
    r.raise_for_status()
    return r.json()


def enqueue_export(space_id: str) -> str:
    """Kick off the export task and return the task ID."""
    payload = {
        "task": {
            "eventName": "exportSpace",
            "request": {
                "spaceId": space_id,
                "exportOptions": {
                    "exportType": EXPORT_TYPE,
                    "timeZone": "UTC",
                    "locale": "en",
                    "includeContents": "everything",  # includes shared pages
                    "flattenExportFiletree": False,
                },
                "shouldExportComments": False,
            },
        }
    }
    r = requests.post(
        f"{BASE_URL}/enqueueTask",
        headers=HEADERS,
        json=payload,
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    task_id = data.get("taskId")
    if not task_id:
        raise RuntimeError(f"No taskId in response: {data}")
    return task_id


def poll_export(task_id: str) -> str:
    """Poll until the export is done; return the download URL."""
    log(f"Polling task {task_id}...")
    deadline = time.time() + MAX_WAIT
    while time.time() < deadline:
        r = requests.post(
            f"{BASE_URL}/getTasks",
            headers=HEADERS,
            json={"taskIds": [task_id]},
            timeout=30,
        )
        r.raise_for_status()
        results = r.json().get("results", [])
        if not results:
            time.sleep(POLL_INTERVAL)
            continue

        task = results[0]
        state = task.get("state")
        status = task.get("status", {})

        if state == "success":
            url = status.get("exportURL")
            if not url:
                raise RuntimeError(f"Export succeeded but no URL: {task}")
            log(f"Export ready — {status.get('pagesExported', '?')} pages exported.")
            return url
        elif state == "failure":
            raise RuntimeError(f"Export task failed: {task}")
        else:
            pages = status.get("pagesExported", "?")
            log(
                f"  State: {state}, pages so far: {pages} — waiting {POLL_INTERVAL}s..."
            )
            time.sleep(POLL_INTERVAL)

    raise TimeoutError(f"Export didn't complete within {MAX_WAIT}s.")


def download_zip(url: str, dest: Path):
    """Stream-download the zip to dest."""
    log(f"Downloading to {dest} ...")
    with requests.get(url, stream=True, timeout=120) as r:
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(chunk_size=1 << 20):  # 1 MB chunks
                f.write(chunk)
    size_mb = dest.stat().st_size / (1 << 20)
    log(f"Downloaded {size_mb:.1f} MB.")


def rotate_backups(backup_dir: Path, keep: int):
    """Delete oldest backups, keeping only `keep` most recent."""
    zips = sorted(backup_dir.glob("notion-backup-*.zip"))
    to_delete = zips[: max(0, len(zips) - keep)]
    for old in to_delete:
        old.unlink()
        log(f"Deleted old backup: {old.name}")


def main():
    if not TOKEN_V2:
        print("ERROR: NOTION_TOKEN_V2 not set.")
        sys.exit(1)
    if not FILE_TOKEN:
        print("ERROR: NOTION_FILE_TOKEN not set.")
        sys.exit(1)

    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Resolve space ID
    if SPACE_ID:
        space_id = SPACE_ID
        log(f"Using pinned space ID: {space_id}")
    else:
        # Fallback: derive from API — non-deterministic if you have multiple workspaces.
        # Set NOTION_SPACE_ID in .env to avoid this.
        log("NOTION_SPACE_ID not set — deriving from API (first workspace found)...")
        user_content = get_user_content()
        spaces = user_content.get("recordMap", {}).get("space", {})
        if not spaces:
            raise RuntimeError("No spaces found — check your token_v2.")
        space_id = next(iter(spaces))
        space_name = spaces[space_id]["value"].get("name", "unknown")
        log(f"Workspace: '{space_name}' (id: {space_id})")
        log("Tip: set NOTION_SPACE_ID in .env to pin this and skip the lookup.")

    # 2. Enqueue export
    log("Enqueueing export task...")
    task_id = enqueue_export(space_id)
    log(f"Task ID: {task_id}")

    # 3. Poll for completion
    download_url = poll_export(task_id)

    # 4. Download
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    zip_path = BACKUP_DIR / f"notion-backup-{timestamp}.zip"
    download_zip(download_url, zip_path)

    # 5. Rotate — keep only KEEP_N backups
    rotate_backups(BACKUP_DIR, KEEP_N)

    log(f"Done. Backups in {BACKUP_DIR}:")
    for f in sorted(BACKUP_DIR.glob("notion-backup-*.zip")):
        log(f"  {f.name}  ({f.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
