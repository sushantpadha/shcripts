#!/bin/bash
# Fuzzy-pick a file under ~ and copy its full path to the clipboard
set -euo pipefail

FD=$(command -v fd || command -v fdfind) || { echo "need fd (apt install fd-find)"; exit 1; }
if [ "${XDG_SESSION_TYPE:-}" = wayland ] && command -v wl-copy >/dev/null; then
    COPY=(setsid -f wl-copy)   # setsid: survive the terminal closing
else
    COPY=(setsid -f xclip -selection clipboard)
fi

cd "$HOME"
FILE=$("$FD" --type f --hidden --exclude .git --exclude .cache --exclude node_modules \
    | fzf --height 40% --reverse --prompt "~/ ") || exit 0

PATH_FULL=$(readlink -f "$FILE")
printf '%s' "$PATH_FULL" | "${COPY[@]}"
echo -e "\033[1;32mcopied:\033[0m $PATH_FULL"
notify-send "Path copied" "$PATH_FULL" 2>/dev/null || true
