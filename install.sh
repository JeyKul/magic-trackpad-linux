#!/bin/sh
# Installs mt2d for the current user. The udev rule needs root once.
set -e
cd "$(dirname "$0")"
install -Dm755 mt2d.py ~/.local/bin/mt2d
install -Dm644 mt2d.service ~/.config/systemd/user/mt2d.service
[ -f ~/.config/mt2d/config.toml ] || install -Dm644 config.example.toml ~/.config/mt2d/config.toml
if [ ! -f /etc/udev/rules.d/70-magic-trackpad.rules ]; then
    sudo install -m644 70-magic-trackpad.rules /etc/udev/rules.d/
    sudo udevadm control --reload
    sudo udevadm trigger -s hidraw
fi
id -nG | grep -qw input || echo "warning: add yourself to the 'input' group (evdev + uinput access)"
systemctl --user daemon-reload
systemctl --user enable --now mt2d.service
echo "mt2d installed. Tune ~/.config/mt2d/config.toml, then: mt2d reload"
