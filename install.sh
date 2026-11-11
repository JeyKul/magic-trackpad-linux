#!/bin/sh
# Per-user install of mt2d. Root is needed once for the udev rule and,
# on KDE Plasma, for the System Settings module.
set -e
cd "$(dirname "$0")"

install -Dm755 mt2d.py ~/.local/bin/mt2d
install -Dm755 gtk/mt2d-settings ~/.local/bin/mt2d-settings
install -Dm644 shaders/ripple.glsl ~/.local/share/mt2d/ripple.glsl
mkdir -p ~/.local/share/applications
sed 's|Exec=mt2d-settings|Exec='"$HOME"'/.local/bin/mt2d-settings|' data/io.github.mt2d.Settings.desktop \
    > ~/.local/share/applications/io.github.mt2d.Settings.desktop
sed 's|/usr/bin/mt2d|%h/.local/bin/mt2d|g' data/mt2d.service | install -Dm644 /dev/stdin ~/.config/systemd/user/mt2d.service
[ -f ~/.config/mt2d/config.toml ] || install -Dm644 config.example.toml ~/.config/mt2d/config.toml

if [ ! -f /etc/udev/rules.d/70-magic-trackpad.rules ]; then
    sudo install -m644 data/70-magic-trackpad.rules /etc/udev/rules.d/
    sudo udevadm control --reload
    sudo udevadm trigger -s hidraw
fi

case "$XDG_CURRENT_DESKTOP" in
*KDE*)
    build=$(mktemp -d)
    cmake -S kde -B "$build" -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$build" -j"$(nproc)" >/dev/null
    sudo cmake --install "$build" >/dev/null
    rm -rf "$build"
    echo "KDE: System Settings > Mouse & Touchpad > Magic Trackpad"
    ;;
*)
    echo "Settings app: Magic Trackpad (mt2d-settings)"
    ;;
esac

id -nG | grep -qw input || echo "warning: add yourself to the 'input' group (evdev + uinput access)"
systemctl --user daemon-reload
systemctl --user enable mt2d.service
systemctl --user restart mt2d.service
echo "mt2d installed and running."
