#!/bin/sh
# One-line install and update for mt2d:
#
#   curl -fsSL https://raw.githubusercontent.com/JeyKul/magic-trackpad-linux/main/get.sh | sh
#
# Installs the dependencies for this distro and desktop, clones (or updates)
# the repository, then runs install.sh. Set MT2D_DRY_RUN=1 to only print the
# commands that would run.
set -eu

REPO=https://github.com/JeyKul/magic-trackpad-linux
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/mt2d/src"

run() {
    echo "+ $*"
    [ -n "${MT2D_DRY_RUN:-}" ] || "$@"
}

case "${XDG_CURRENT_DESKTOP:-}" in
*KDE*) ui=kde ;;
*) ui=gtk ;;
esac

if command -v pacman >/dev/null; then
    base="git python python-evdev"
    kde="cmake extra-cmake-modules gcc kcmutils ki18n kcoreaddons kirigami qt6-declarative qt6-shadertools"
    gtk="python-gobject gtk4 libadwaita python-opengl"
    install="sudo pacman -S --needed --noconfirm"
elif command -v apt-get >/dev/null; then
    base="git python3 python3-evdev"
    kde="cmake extra-cmake-modules g++ libkf6kcmutils-dev libkf6i18n-dev libkf6coreaddons-dev qt6-declarative-dev qt6-shadertools-dev qml6-module-org-kde-kirigami qml6-module-org-kde-kcmutils"
    gtk="python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 python3-opengl"
    install="sudo apt-get install -y"
    run sudo apt-get update
elif command -v dnf >/dev/null; then
    base="git python3 python3-evdev"
    kde="cmake extra-cmake-modules gcc-c++ kf6-kcmutils-devel kf6-ki18n-devel kf6-kcoreaddons-devel kf6-kirigami qt6-qtdeclarative-devel qt6-qtshadertools-devel"
    gtk="python3-gobject gtk4 libadwaita python3-pyopengl"
    install="sudo dnf install -y"
else
    echo "Unknown package manager: install the requirements from the README by hand." >&2
    install=""
fi

if [ -n "$install" ]; then
    if [ "$ui" = kde ]; then pkgs="$base $kde"; else pkgs="$base $gtk"; fi
    echo "Installing dependencies for the $ui settings UI:"
    # Word splitting of $install and $pkgs is intended
    # shellcheck disable=SC2086
    run $install $pkgs
fi

if [ -z "${MT2D_DRY_RUN:-}" ] && ! python3 -c 'import tomllib, evdev' 2>/dev/null; then
    echo "mt2d needs Python 3.11 or newer with python-evdev." >&2
    exit 1
fi

if [ -d "$DIR/.git" ]; then
    run git -C "$DIR" pull --ff-only
else
    run mkdir -p "$(dirname "$DIR")"
    run git clone --depth 1 "$REPO" "$DIR"
fi

run sh "$DIR/install.sh"
