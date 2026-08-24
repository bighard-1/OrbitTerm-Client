#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/.tooling/freerdp-macos"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
SOURCE_DIR="${WORK_DIR}/sources"
BUILD_DIR="${WORK_DIR}/build"
INSTALL_DIR="${WORK_DIR}/install"
TOOLS_DIR="${HOME}/Library/Python/3.9/bin"

FREERDP_VERSION="3.26.0"
FREERDP_SHA256="55fa5c3159399886ba4adbe2c8a10d0b1c0484022efdf3827f68adc478b944d5"
FREERDP_URL="https://github.com/FreeRDP/FreeRDP/releases/download/${FREERDP_VERSION}/freerdp-${FREERDP_VERSION}.tar.gz"
OPENSSL_VERSION="3.6.0"
OPENSSL_SHA256="b6a5f44b7eb69e3fa35dbf15524405b44837a481d43d81daddde3ff21fcbb8e9"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"

export PATH="${TOOLS_DIR}:${PATH}"

for tool in curl shasum tar cmake ninja make perl xcrun; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'Required build tool is missing: %s\n' "${tool}" >&2
    exit 1
  fi
done

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  printf 'This stage currently produces the audited macOS arm64 runtime only.\n' >&2
  exit 1
fi

mkdir -p "${DOWNLOAD_DIR}" "${SOURCE_DIR}" "${BUILD_DIR}" "${INSTALL_DIR}"

download_and_verify() {
  local url="$1"
  local expected="$2"
  local output="$3"
  if [[ ! -f "${output}" ]]; then
    curl --fail --location --retry 3 --output "${output}" "${url}"
  fi
  local actual
  actual="$(shasum -a 256 "${output}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Checksum mismatch for %s\nexpected: %s\nactual:   %s\n' "${output}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

extract_once() {
  local archive="$1"
  local marker="$2"
  if [[ ! -f "${marker}" ]]; then
    tar -xzf "${archive}" -C "${SOURCE_DIR}"
    touch "${marker}"
  fi
}

FREERDP_ARCHIVE="${DOWNLOAD_DIR}/freerdp-${FREERDP_VERSION}.tar.gz"
OPENSSL_ARCHIVE="${DOWNLOAD_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
download_and_verify "${FREERDP_URL}" "${FREERDP_SHA256}" "${FREERDP_ARCHIVE}"
download_and_verify "${OPENSSL_URL}" "${OPENSSL_SHA256}" "${OPENSSL_ARCHIVE}"
extract_once "${FREERDP_ARCHIVE}" "${SOURCE_DIR}/.freerdp-${FREERDP_VERSION}-extracted"
extract_once "${OPENSSL_ARCHIVE}" "${SOURCE_DIR}/.openssl-${OPENSSL_VERSION}-extracted"

OPENSSL_SOURCE="${SOURCE_DIR}/openssl-${OPENSSL_VERSION}"
OPENSSL_BUILD="${BUILD_DIR}/openssl-${OPENSSL_VERSION}"
OPENSSL_INSTALL="${INSTALL_DIR}/openssl"
if [[ ! -f "${OPENSSL_INSTALL}/lib/libcrypto.3.dylib" ]]; then
  mkdir -p "${OPENSSL_BUILD}"
  (
    cd "${OPENSSL_BUILD}"
    "${OPENSSL_SOURCE}/Configure" darwin64-arm64-cc shared no-apps no-docs no-tests \
      --prefix="${OPENSSL_INSTALL}" --openssldir="${OPENSSL_INSTALL}/ssl" \
      -mmacosx-version-min=14.0
    make -s -j "$(sysctl -n hw.ncpu)" build_sw
    make -s install_sw
  )
fi

FREERDP_SOURCE="${SOURCE_DIR}/freerdp-${FREERDP_VERSION}"
FREERDP_BUILD="${BUILD_DIR}/freerdp-${FREERDP_VERSION}"
FREERDP_INSTALL="${INSTALL_DIR}/freerdp"

cmake -S "${FREERDP_SOURCE}" -B "${FREERDP_BUILD}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_INSTALL_PREFIX="${FREERDP_INSTALL}" \
  -DCMAKE_PREFIX_PATH="${OPENSSL_INSTALL}" \
  -DOPENSSL_ROOT_DIR="${OPENSSL_INSTALL}" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_CHANNELS=ON \
  -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_SERVER_CHANNELS=OFF \
  -DWITH_X11=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_OPENH264=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_MACAUDIO=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_WEBVIEW=OFF \
  -DCHANNEL_URBDRC=OFF \
  -DCHANNEL_SMARTCARD=OFF \
  -DCHANNEL_PRINTER=OFF \
  -DWITH_INTERNAL_MD4=ON \
  -DWITH_INTERNAL_MD5=ON \
  -DWITH_INTERNAL_RC4=ON

cmake --build "${FREERDP_BUILD}"
cmake --install "${FREERDP_BUILD}"

OPENSSL_LIBRARY_DIR="${OPENSSL_INSTALL}/lib"
FREERDP_LIBRARY_DIR="${FREERDP_INSTALL}/lib"
install_name_tool -id '@rpath/libcrypto.3.dylib' "${OPENSSL_LIBRARY_DIR}/libcrypto.3.dylib"
install_name_tool -id '@rpath/libssl.3.dylib' "${OPENSSL_LIBRARY_DIR}/libssl.3.dylib"
install_name_tool -change "${OPENSSL_LIBRARY_DIR}/libcrypto.3.dylib" '@rpath/libcrypto.3.dylib' \
  "${OPENSSL_LIBRARY_DIR}/libssl.3.dylib"

while IFS= read -r library; do
  install_name_tool -change "${OPENSSL_LIBRARY_DIR}/libssl.3.dylib" '@rpath/libssl.3.dylib' "${library}" 2>/dev/null || true
  install_name_tool -change "${OPENSSL_LIBRARY_DIR}/libcrypto.3.dylib" '@rpath/libcrypto.3.dylib' "${library}" 2>/dev/null || true
done < <(find "${FREERDP_LIBRARY_DIR}" -type f -name '*.dylib' | sort)

mkdir -p "${FREERDP_INSTALL}/share/licenses"
cp "${FREERDP_SOURCE}/LICENSE" "${FREERDP_INSTALL}/share/licenses/FreeRDP-Apache-2.0.txt"
cp "${OPENSSL_SOURCE}/LICENSE.txt" "${FREERDP_INSTALL}/share/licenses/OpenSSL-Apache-2.0.txt"
cp "${ROOT_DIR}/third_party/freerdp/manifest.json" "${FREERDP_INSTALL}/share/licenses/orbitterm-freerdp-manifest.json"

printf 'FreeRDP runtime ready at %s\n' "${FREERDP_INSTALL}"
