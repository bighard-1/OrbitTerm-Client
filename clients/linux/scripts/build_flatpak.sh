#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"
flatpak_root="$linux_root/packaging/flatpak"
vendor_root="$flatpak_root/vendor"
source_root="$flatpak_root/sources"
freerdp_archive="$source_root/freerdp-3.30.0.tar.gz"
freerdp_sha256="e2687d02dea6fede004d36391dac1a74ce57a210f8867fd95033171d4909590c"
vte_archive="$source_root/vte-0.84.1.tar.xz"
vte_sha256="aca1caa8478aebcdbb1d67897fb3511eb7601debae6810e16a15b6fa25f31ac8"

source "$HOME/.cargo/env" 2>/dev/null || true
mkdir -p "$vendor_root"
mkdir -p "$source_root"
if [[ ! -f "$freerdp_archive" ]] ||
    [[ "$(sha256sum "$freerdp_archive" | awk '{print $1}')" != "$freerdp_sha256" ]]; then
    temporary_archive="$(mktemp "$source_root/.freerdp-3.30.0.XXXXXX")"
    trap 'rm -f "$temporary_archive"' EXIT
    curl --proto '=https' --tlsv1.2 --fail --location \
        --retry 5 --retry-all-errors --connect-timeout 20 --max-time 300 \
        'https://github.com/FreeRDP/FreeRDP/releases/download/3.30.0/freerdp-3.30.0.tar.gz' \
        --output "$temporary_archive"
    echo "$freerdp_sha256  $temporary_archive" | sha256sum --check --status
    mv "$temporary_archive" "$freerdp_archive"
    trap - EXIT
fi
if [[ ! -f "$vte_archive" ]] ||
    [[ "$(sha256sum "$vte_archive" | awk '{print $1}')" != "$vte_sha256" ]]; then
    temporary_archive="$(mktemp "$source_root/.vte-0.84.1.XXXXXX")"
    trap 'rm -f "$temporary_archive"' EXIT
    curl --proto '=https' --tlsv1.2 --fail --location \
        --retry 5 --retry-all-errors --connect-timeout 20 --max-time 300 \
        'https://download.gnome.org/sources/vte/0.84/vte-0.84.1.tar.xz' \
        --output "$temporary_archive"
    echo "$vte_sha256  $temporary_archive" | sha256sum --check --status
    mv "$temporary_archive" "$vte_archive"
    trap - EXIT
fi
cargo vendor --quiet --locked --manifest-path "$linux_root/Cargo.toml" "$vendor_root"

flatpak install --user --noninteractive -y flathub \
    org.gnome.Platform//50 \
    org.gnome.Sdk//50 \
    org.freedesktop.Sdk.Extension.rust-stable//25.08

cd "$flatpak_root"
flatpak-builder \
    --user \
    --force-clean \
    --install-deps-from=flathub \
    --repo=repo \
    build-dir \
    com.orbitterm.Client.json

flatpak build-bundle repo OrbitTerm.flatpak com.orbitterm.Client
test -f "$flatpak_root/OrbitTerm.flatpak"
echo "Flatpak bundle: $flatpak_root/OrbitTerm.flatpak"
