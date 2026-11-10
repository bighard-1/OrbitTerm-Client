#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
    echo "无法识别 Linux 发行版。" >&2
    exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "此脚本只维护 Ubuntu 依赖；当前系统为 ${ID:-unknown}。" >&2
    exit 1
fi

sudo apt-get update
sudo apt-get install -y \
    build-essential \
    clang \
    cmake \
    curl \
    dbus-x11 \
    desktop-file-utils \
    flatpak \
    flatpak-builder \
    freerdp3-dev \
    gettext \
    git \
    jq \
    libadwaita-1-dev \
    libgtk-4-dev \
    libsecret-1-dev \
    libsqlite3-dev \
    libssl-dev \
    libwinpr3-dev \
    libxkbcommon-dev \
    libvte-2.91-gtk4-dev \
    meson \
    ninja-build \
    pkg-config \
    ripgrep \
    rsync

if ! command -v rustup >/dev/null 2>&1; then
    installer="$(mktemp /tmp/orbitterm-rustup.XXXXXX)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$installer"
    sh "$installer" -y --profile minimal --default-toolchain stable
    unlink "$installer"
fi

source "$HOME/.cargo/env"
rustup component add clippy rustfmt
rustc -V
cargo -V
