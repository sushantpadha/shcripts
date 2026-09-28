#!/bin/bash
# Bind Super+V to the CopyQ clipboard menu in GNOME (keeps your other custom shortcuts)
set -euo pipefail

KEY=org.gnome.settings-daemon.plugins.media-keys
SLOT=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq/

# reuse an existing CopyQ shortcut slot if there is one
for s in $(gsettings get $KEY custom-keybindings | grep -o "'[^']*'" | tr -d "'"); do
    [ "$(gsettings get $KEY.custom-keybinding:$s command)" = "'copyq menu'" ] && SLOT=$s
done

# free Super+V: GNOME uses it for the notification tray, move that to Super+M
gsettings set org.gnome.shell.keybindings toggle-message-tray "['<Super>m']"

# add our slot to the custom shortcut list only if missing
list=$(gsettings get $KEY custom-keybindings)
if [[ "$list" != *"$SLOT"* ]]; then
    if [[ "$list" == "@as []" || "$list" == "[]" ]]; then
        list="['$SLOT']"
    else
        list="${list%]}, '$SLOT']"
    fi
    gsettings set $KEY custom-keybindings "$list"
fi

gsettings set $KEY.custom-keybinding:$SLOT name 'CopyQ Menu'
gsettings set $KEY.custom-keybinding:$SLOT command 'copyq menu'
gsettings set $KEY.custom-keybinding:$SLOT binding '<Super>v'

echo -e "\033[1;32m+\033[0m Super+V -> copyq menu   (notification tray moved to Super+M)"
