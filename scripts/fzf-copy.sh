#!/bin/bash
# Uses fd for speed and xclip for the clipboard
FILE=$(fd --type f --hidden --exclude .git | fzf --height 40% --reverse)
if [ -n "$FILE" ]; then
    readlink -f "$FILE" | xclip -selection clipboard
    notify-send "Path Copied" "$FILE"
fi

