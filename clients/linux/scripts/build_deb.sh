#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$linux_root/../.." && pwd)"
stage="$(mktemp -d /tmp/orbitterm-deb.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
chmod 0755 "$stage"

binary="$("$script_dir/build_release.sh" --print-binary-path)"
python3 - "$binary" <<'PY'
import sys

with open(sys.argv[1], "rb") as executable:
    header = executable.read(20)
if header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20], "little") != 62:
    sys.exit("The amd64 Debian package requires an x86-64 Linux ELF executable.")
PY

install -Dm755 \
    "$binary" \
    "$stage/usr/bin/orbitterm-linux"
install -Dm644 \
    "$linux_root/data/com.orbitterm.Client.desktop" \
    "$stage/usr/share/applications/com.orbitterm.Client.desktop"
install -Dm644 \
    "$linux_root/data/com.orbitterm.Client.metainfo.xml" \
    "$stage/usr/share/metainfo/com.orbitterm.Client.metainfo.xml"
install -Dm644 \
    "$repo_root/OrbitTerm/Assets.xcassets/AppIcon.appiconset/mac-512@1x.png" \
    "$stage/usr/share/icons/hicolor/512x512/apps/com.orbitterm.Client.png"
install -Dm644 \
    "$linux_root/packaging/debian/DEBIAN/control" \
    "$stage/DEBIAN/control"

mkdir -p "$repo_root/dist"
dpkg-deb --root-owner-group --build "$stage" "$repo_root/dist/orbitterm_0.1.0_amd64.deb"
dpkg-deb --info "$repo_root/dist/orbitterm_0.1.0_amd64.deb"
