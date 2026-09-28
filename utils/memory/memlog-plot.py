#!/usr/bin/env python3
"""Plot memlog.txt. Usage: memlog-plot.py [hours]   (no argument = all data)

Top: MB used by the biggest programs. Middle: free RAM. Bottom: swap used + memory pressure.
"""
import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import numpy as np

LOG = Path(os.environ.get("MEMLOG", Path.home() / "shcripts/logs/memlog.txt"))
WARN_MB = 1500              # keep in sync with memlog.sh
GAP = timedelta(minutes=3)  # longer gap = logging was off or the machine slept: break the lines
NPROG = 6


def load():
    rows = []
    for f in (LOG.with_name(LOG.name + ".old"), LOG):
        if not f.exists():
            continue
        for line in f.read_text().splitlines():
            try:
                ts = datetime.strptime(line[:19], "%Y-%m-%d %H:%M:%S")
                head, top = line[19:].split("top=")
                v = dict(kv.split("=") for kv in head.split())
                progs = {p.rsplit(":", 1)[0]: float(p.rsplit(":", 1)[1]) for p in top.split()}
                rows.append((ts, float(v["avail_mb"]), float(v["swap_mb"]), float(v["psi"]), progs))
            except (ValueError, IndexError, KeyError):
                continue  # torn line or old format: skip
    return rows


def with_gaps(rows):
    """Insert an all-NaN row inside every long gap so lines break there."""
    out = []
    for i, r in enumerate(rows):
        out.append(r)
        if i + 1 < len(rows) and rows[i + 1][0] - r[0] > GAP:
            out.append((r[0] + GAP / 2, np.nan, np.nan, np.nan, None))
    return out


rows = load()
if len(sys.argv) > 1:
    cutoff = datetime.now() - timedelta(hours=float(sys.argv[1]))
    rows = [r for r in rows if r[0] >= cutoff]
if len(rows) < 2:
    sys.exit("not enough log data yet for that time range")

peak = {}
for r in rows:
    for name, mb in r[4].items():
        peak[name] = max(peak.get(name, 0), mb)
names = sorted(peak, key=peak.get, reverse=True)[:NPROG]

plot_rows = with_gaps(rows)
t = [r[0] for r in plot_rows]
avail = np.array([r[1] for r in plot_rows])
swap = np.array([r[2] for r in plot_rows])
psi = np.array([r[3] for r in plot_rows])

fig, (a0, a1, a2) = plt.subplots(3, 1, sharex=True, figsize=(12, 8),
                                 gridspec_kw={"height_ratios": [3, 2, 2]})

for name in names:
    y = [np.nan if r[4] is None else r[4].get(name, 0) for r in plot_rows]
    a0.plot(t, y, label=name, linewidth=1.4)
a0.set_ylabel("MB used")
a0.set_title("Biggest programs")
a0.legend(ncol=NPROG, loc="upper left", fontsize=8)

a1.fill_between(t, avail, color="tab:green", alpha=0.35)
a1.plot(t, avail, color="tab:green", linewidth=1)
a1.axhline(WARN_MB, color="tab:red", linestyle="--", linewidth=1, label=f"warning ({WARN_MB} MB)")
low = int(np.nanargmin(avail))
a1.annotate(f"lowest: {avail[low]:.0f} MB\n{t[low]:%d %b %H:%M}", xy=(t[low], avail[low]),
            xytext=(20, 30), textcoords="offset points", fontsize=8,
            arrowprops={"arrowstyle": "->"})
a1.set_ylim(bottom=0)
a1.set_ylabel("MB free")
a1.set_title("Free RAM (drops toward 0 = trouble)")
a1.legend(loc="upper right", fontsize=8)

a2.plot(t, swap, color="tab:purple", linewidth=1.4)
a2.fill_between(t, swap, color="tab:purple", alpha=0.2)
a2.set_ylim(bottom=0)
a2.set_ylabel("swap used (MB)", color="tab:purple")
b2 = a2.twinx()
b2.plot(t, psi, color="tab:orange", linewidth=1)
b2.set_ylim(bottom=0)
b2.set_ylabel("memory pressure %", color="tab:orange")
a2.set_title("Swap used and memory pressure (pressure above ~10% = system is stalling)")

loc = mdates.AutoDateLocator()
a2.xaxis.set_major_locator(loc)
a2.xaxis.set_major_formatter(mdates.ConciseDateFormatter(loc))
for ax in (a0, a1, a2):
    ax.grid(alpha=0.3)

fig.suptitle(f"Memory log: {rows[0][0]:%d %b %H:%M} to {rows[-1][0]:%d %b %H:%M}  ({len(rows)} snapshots)")
fig.tight_layout()
plt.show()
