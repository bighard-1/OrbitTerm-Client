# Apple Protected Release Setup

This document prepares a release process; it does not place Apple credentials
in source control and it does not authorize a public release by itself.

## Before enabling the workflow

1. Enrol the legal publisher in the Apple Developer Program.
2. Register the `com.orbitterm.app` application identifier for iOS and macOS.
3. Create and export, separately, an Apple Distribution certificate and a
   Developer ID Application certificate. Do not reuse a local development
   certificate for public release.
4. Create an App Store Connect API key with the minimum role required for
   notarization, then keep its `.p8` private key outside the repository.
5. Create the intended iOS distribution provisioning profile and an
   `ExportOptions.plist` that selects the reviewed distribution method.
6. Create the GitHub `apple-production-release` environment and require at
   least one reviewer. It must not be available to ordinary pull requests.

## Protected environment secrets

Configure these as **environment secrets**, not repository variables:

| Secret | Purpose |
| --- | --- |
| `ORBITTERM_RELEASE_KEYCHAIN_PASSWORD` | Ephemeral CI keychain password |
| `ORBITTERM_IOS_DISTRIBUTION_P12_BASE64` | Base64 Apple Distribution `.p12` |
| `ORBITTERM_IOS_DISTRIBUTION_P12_PASSWORD` | P12 password |
| `ORBITTERM_MACOS_DEVELOPER_ID_P12_BASE64` | Base64 Developer ID Application `.p12` |
| `ORBITTERM_MACOS_DEVELOPER_ID_P12_PASSWORD` | P12 password |
| `ORBITTERM_IOS_PROVISIONING_PROFILE_BASE64` | Base64 iOS distribution profile |
| `ORBITTERM_IOS_EXPORT_OPTIONS_PLIST_BASE64` | Base64 reviewed iOS export options |
| `ORBITTERM_NOTARY_API_KEY_BASE64` | Base64 App Store Connect API `.p8` |
| `ORBITTERM_NOTARY_KEY_ID` | App Store Connect API key ID |
| `ORBITTERM_NOTARY_ISSUER_ID` | App Store Connect issuer ID |
| `ORBITTERM_APPLE_TEAM_ID` | Apple team identifier |
| `ORBITTERM_IOS_CODESIGN_IDENTITY` | Exact Apple Distribution identity name |
| `ORBITTERM_IOS_PROVISIONING_PROFILE_SPECIFIER` | Exact iOS profile name |
| `ORBITTERM_MACOS_CODESIGN_IDENTITY` | Exact Developer ID Application identity name |

Never paste any of these values into a task, commit, issue, diagnostics export,
or release note. Rotate a credential immediately if it has been exposed.

## Dispatch procedure

1. Merge reviewed work to `main`, wait for the ordinary `Security Gates`
   workflow to succeed, then record the full 40-character commit SHA.
2. Complete and review the sanitized real-device performance evidence required
   by `docs/release/APPLE_DEVICE_PERFORMANCE_SLO.md`. It is a human release
   approval input, intentionally not fabricated by CI.
3. Manually dispatch `Apple Protected Release` with that exact SHA and the
   approved marketing version. The workflow fails closed without a successful
   ordinary gate for exactly the same commit or without protected signing
   credentials.
4. Review the uploaded IPA, notarized DMG, evidence bundle and checksums.
   Only then create a GitHub Release or submit the iOS build in App Store
   Connect. Artifact upload is deliberately separate from public promotion.

## TLS pin rotation

The official client pins the SPKI SHA-256 hash of
`server.orbitterm.com`. Before changing the production TLS public key:

1. Extract the current and next SPKI hashes from the serving certificate and
   planned replacement certificate.
2. Add the next hash to `OfficialServiceTLSPinningPolicy.acceptedSPKIHashes`
   while retaining the current hash.
3. Ship that client version and wait until all supported release channels can
   accept both hashes.
4. Deploy the replacement certificate/key, verify ordinary TLS and client
   connectivity, then remove the retired hash only in a later client release.

Do not switch the official endpoint to a self-hosted/custom URL as a rotation
mechanism. Custom endpoints remain HTTPS-only and require an explicit
host-specific risk confirmation.
