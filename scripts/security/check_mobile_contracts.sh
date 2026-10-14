#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="$root/build/mobile-contracts"
mkdir -p "$output"
developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
# Pure policy lane: does not require rebuilding Rust or desktop RDP libraries.
xcrun swiftc \
  -F "$developer/Library/Frameworks" \
  -I "$developer/usr/lib" \
  -L "$developer/usr/lib" \
  -Xlinker -rpath -Xlinker "$developer/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$developer/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$developer/usr/lib" \
  "$root/OrbitTerm/Core/AdministratorContactPolicy.swift" \
  "$root/OrbitTerm/Core/AdministratorContactStore.swift" \
  "$root/OrbitTerm/Core/TerminalCustomKeyPayload.swift" \
  "$root/OrbitTerm/Core/TerminalCustomKeySyncCompatibility.swift" \
  "$root/OrbitTerm/Core/TerminalCustomKeyContract.swift" \
  "$root/OrbitTermCheckedFFITests/TerminalCustomKeyContractTests.swift" \
  "$root/OrbitTermCheckedFFITests/MobileContractPolicyTests.swift" \
  "$root/OrbitTermCheckedFFITests/AdministratorContactStoreTests.swift" \
  "$root/tests/mobile-contracts/ContractTestMain.swift" \
  -o "$output/contract-tests"
"$output/contract-tests"
