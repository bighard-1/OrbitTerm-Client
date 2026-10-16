#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd -- "${script_dir}/.." && pwd)"
bundle="${1:-${linux_root}/packaging/flatpak/OrbitTerm.flatpak}"

test -f "${bundle}"
flatpak install --user --noninteractive -y --reinstall "${bundle}"

export_root="${HOME}/.local/share/flatpak/exports/share"
exported_desktop="${export_root}/applications/com.orbitterm.Client.desktop"
exported_icon="${export_root}/icons/hicolor/512x512/apps/com.orbitterm.Client.png"
test -e "${exported_desktop}"
test -e "${exported_icon}"

# Some long-running GNOME sessions were started without Flatpak's user export
# directory in XDG_DATA_DIRS. Mirror the exported launcher into the standard
# per-user locations so the application menu can discover it immediately.
menu_desktop="${HOME}/.local/share/applications/com.orbitterm.Client.desktop"
menu_icon="${HOME}/.local/share/icons/hicolor/512x512/apps/com.orbitterm.Client.png"
install -Dm644 "${exported_desktop}" "${menu_desktop}"
install -Dm644 "${exported_icon}" "${menu_icon}"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${HOME}/.local/share/applications"
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache --force --ignore-theme-index "${HOME}/.local/share/icons/hicolor" >/dev/null
fi

desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
if [[ -n "${desktop_dir}" && "${desktop_dir}" != "${HOME}" ]]; then
    desktop_launcher="${desktop_dir}/OrbitTerm.desktop"
    install -Dm755 "${menu_desktop}" "${desktop_launcher}"
    gio set "${desktop_launcher}" metadata::trusted true >/dev/null 2>&1 || true
fi

echo "Installed Flatpak: $(flatpak info --user --show-commit com.orbitterm.Client)"
echo "Application menu launcher: ${menu_desktop}"
if [[ -n "${desktop_dir}" && "${desktop_dir}" != "${HOME}" ]]; then
    echo "Desktop launcher: ${desktop_dir}/OrbitTerm.desktop"
fi
