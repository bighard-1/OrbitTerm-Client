#!/usr/bin/env bash

set -euo pipefail

require() {
  [[ -n "${!1:-}" ]] || { echo "missing protected release variable: $1" >&2; exit 1; }
}

for variable in \
  ORBITTERM_RELEASE_KEYCHAIN_PATH \
  ORBITTERM_RELEASE_KEYCHAIN_PASSWORD \
  ORBITTERM_IOS_DISTRIBUTION_P12_BASE64 \
  ORBITTERM_IOS_DISTRIBUTION_P12_PASSWORD \
  ORBITTERM_MACOS_DEVELOPER_ID_P12_BASE64 \
  ORBITTERM_MACOS_DEVELOPER_ID_P12_PASSWORD \
  ORBITTERM_IOS_PROVISIONING_PROFILE_BASE64 \
  ORBITTERM_IOS_EXPORT_OPTIONS_PLIST_BASE64 \
  ORBITTERM_NOTARY_API_KEY_BASE64 \
  ORBITTERM_NOTARY_KEY_ID \
  ORBITTERM_NOTARY_ISSUER_ID; do
  require "$variable"
done

decode() {
  local encoded="$1"
  local output="$2"
  printf '%s' "$encoded" | base64 -D > "$output"
  chmod 600 "$output"
}

keychain_dir="$(dirname "$ORBITTERM_RELEASE_KEYCHAIN_PATH")"
mkdir -p "$keychain_dir"
security create-keychain -p "$ORBITTERM_RELEASE_KEYCHAIN_PASSWORD" "$ORBITTERM_RELEASE_KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$ORBITTERM_RELEASE_KEYCHAIN_PATH"
security unlock-keychain -p "$ORBITTERM_RELEASE_KEYCHAIN_PASSWORD" "$ORBITTERM_RELEASE_KEYCHAIN_PATH"
security list-keychain -d user -s "$ORBITTERM_RELEASE_KEYCHAIN_PATH"

decode "$ORBITTERM_IOS_DISTRIBUTION_P12_BASE64" "$keychain_dir/ios-distribution.p12"
decode "$ORBITTERM_MACOS_DEVELOPER_ID_P12_BASE64" "$keychain_dir/macos-developer-id.p12"
security import "$keychain_dir/ios-distribution.p12" -k "$ORBITTERM_RELEASE_KEYCHAIN_PATH" -P "$ORBITTERM_IOS_DISTRIBUTION_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security import "$keychain_dir/macos-developer-id.p12" -k "$ORBITTERM_RELEASE_KEYCHAIN_PATH" -P "$ORBITTERM_MACOS_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$ORBITTERM_RELEASE_KEYCHAIN_PASSWORD" "$ORBITTERM_RELEASE_KEYCHAIN_PATH"

profiles_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles_dir"
decode "$ORBITTERM_IOS_PROVISIONING_PROFILE_BASE64" "$profiles_dir/orbitterm-release.mobileprovision"
decode "$ORBITTERM_IOS_EXPORT_OPTIONS_PLIST_BASE64" "$keychain_dir/ExportOptions.plist"
decode "$ORBITTERM_NOTARY_API_KEY_BASE64" "$keychain_dir/AuthKey.p8"

plutil -lint "$keychain_dir/ExportOptions.plist" >/dev/null
security find-identity -v -p codesigning "$ORBITTERM_RELEASE_KEYCHAIN_PATH"

echo "ORBITTERM_IOS_EXPORT_OPTIONS_PLIST=$keychain_dir/ExportOptions.plist" >> "$GITHUB_ENV"
echo "ORBITTERM_NOTARY_API_KEY_PATH=$keychain_dir/AuthKey.p8" >> "$GITHUB_ENV"
