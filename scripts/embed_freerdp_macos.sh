#!/usr/bin/env bash
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" != "macosx" ]]; then
  exit 0
fi

ROOT_DIR="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RUNTIME_ROOT="${ROOT_DIR}/.tooling/freerdp-macos/install"
FREERDP_LIB="${RUNTIME_ROOT}/freerdp/lib"
OPENSSL_LIB="${RUNTIME_ROOT}/openssl/lib"
DESTINATION="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
LICENSE_DESTINATION="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/ThirdPartyLicenses"

required=(
  "${FREERDP_LIB}/libfreerdp3.3.dylib"
  "${FREERDP_LIB}/libfreerdp-client3.3.dylib"
  "${FREERDP_LIB}/libwinpr3.3.dylib"
  "${FREERDP_LIB}/libwinpr-tools3.3.dylib"
  "${OPENSSL_LIB}/libssl.3.dylib"
  "${OPENSSL_LIB}/libcrypto.3.dylib"
)

for library in "${required[@]}"; do
  if [[ ! -f "${library}" ]]; then
    printf 'Audited FreeRDP runtime is absent; build remains fail-closed. Missing %s\n' "${library}"
    exit 0
  fi
done

mkdir -p "${DESTINATION}"
for library in "${required[@]}"; do
  cp -L "${library}" "${DESTINATION}/$(basename "${library}")"
done

mkdir -p "${LICENSE_DESTINATION}"
cp "${RUNTIME_ROOT}/freerdp/share/licenses/FreeRDP-Apache-2.0.txt" "${LICENSE_DESTINATION}/"
cp "${RUNTIME_ROOT}/freerdp/share/licenses/OpenSSL-Apache-2.0.txt" "${LICENSE_DESTINATION}/"
cp "${ROOT_DIR}/third_party/freerdp/manifest.json" "${LICENSE_DESTINATION}/FreeRDP-manifest.json"

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  for library in "${DESTINATION}"/*.dylib; do
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --timestamp=none "${library}"
  done
fi
