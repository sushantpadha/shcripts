#!/usr/bin/env python3
"""Tray icon that toggles memory logging on/off. Runs memlog.sh every 60s while ON."""
import subprocess
import sys
from pathlib import Path

from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtGui import QColor, QFont, QIcon, QPainter, QPixmap
from PyQt5.QtWidgets import QAction, QApplication, QMenu, QSystemTrayIcon

HERE = Path(__file__).resolve().parent   # utils/memory
SH = HERE.parents[1] / "scripts/memory"  # the shell scripts
LOG = Path.home() / "shcripts/logs/memlog.txt"
AUTOSTART = Path.home() / ".config/autostart/memlog.desktop"
INTERVAL_MS = 60_000

app = QApplication(sys.argv)
app.setQuitOnLastWindowClosed(False)

tray = QSystemTrayIcon()
menu = QMenu()
toggle = QAction()
timer = QTimer()


def snapshot():
    subprocess.Popen([str(SH / "memlog.sh")])


def make_icon(color):
    """Draw the icon ourselves; theme icons don't resolve under this Qt setup."""
    pm = QPixmap(64, 64)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    p.setBrush(QColor(color))
    p.setPen(Qt.NoPen)
    p.drawRoundedRect(4, 4, 56, 56, 12, 12)
    p.setPen(QColor("white"))
    p.setFont(QFont("sans", 34, QFont.Bold))
    p.drawText(pm.rect(), Qt.AlignCenter, "M")
    p.end()
    return QIcon(pm)


ICON_ON, ICON_OFF = make_icon("#2ea043"), make_icon("#6e7681")


def render():
    on = timer.isActive()
    tray.setIcon(ICON_ON if on else ICON_OFF)
    tray.setToolTip("Memory log: ON" if on else "Memory log: OFF")
    toggle.setText("Stop logging" if on else "Start logging")


def flip():
    if timer.isActive():
        timer.stop()
    else:
        snapshot()
        timer.start(INTERVAL_MS)
    render()


def set_autostart(enabled):
    if enabled:
        AUTOSTART.parent.mkdir(parents=True, exist_ok=True)
        AUTOSTART.write_text(
            "[Desktop Entry]\nType=Application\nName=Memory log tray\n"
            f"Exec=/bin/bash {SH / 'start-memlog-service.sh'}\n"
            "X-GNOME-Autostart-enabled=true\n")
    else:
        AUTOSTART.unlink(missing_ok=True)


timer.timeout.connect(snapshot)
toggle.triggered.connect(flip)
menu.addAction(toggle)
menu.addAction("Show report").triggered.connect(
    lambda: subprocess.Popen(["kitty", "--hold", "bash", str(SH / "memlog-report.sh")]))
plot_menu = menu.addMenu("Plot")
for label, hours in [("Last hour", 1), ("Last 6 hours", 6), ("Last 24 hours", 24), ("All data", None)]:
    plot_menu.addAction(label).triggered.connect(
        lambda _checked, h=hours: subprocess.Popen(
            ["python3", str(HERE / "memlog-plot.py"), *([str(h)] if h else [])]))
menu.addAction("Open log").triggered.connect(
    lambda: subprocess.Popen(["xdg-open", str(LOG)]))
menu.addSeparator()
autostart = menu.addAction("Start at login")
autostart.setCheckable(True)
autostart.setChecked(AUTOSTART.exists())
autostart.toggled.connect(set_autostart)
menu.addAction("Quit").triggered.connect(app.quit)

tray.setContextMenu(menu)
flip()  # starts ON
tray.show()
sys.exit(app.exec_())
