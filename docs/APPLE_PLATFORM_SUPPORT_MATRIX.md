# Apple Platform Support Matrix

## Declared build support

| Platform | Architecture | Minimum OS | Debug build | Release build | Automated runtime tests |
| --- | --- | --- | --- | --- | --- |
| macOS | Apple Silicon (`arm64`) | macOS 14 | Required | Required | Lifecycle/late-callback XCTest; UI target compile contract; signed UI smoke lane for release candidates |
| macOS | Intel (`x86_64`) | — | Not supported | Not supported | Not run |
| iOS device | `arm64` | iOS 17 | Required source build | Required source build | Requires a separately provisioned physical-device UI lane |
| iOS Simulator | Apple Silicon (`arm64`) | iOS 17 | Required | Required | Simulator UI root-lifecycle tests plus checked FFI XCTest |

## Contract

- `project.yml` explicitly pins macOS, iPhoneOS, and iPhoneSimulator to `arm64`.
- Every declared Apple architecture builds the same locked Rust core in Debug and
  Release before the Swift target links it.
- The Apple gate checks the checked FFI symbol evidence for all three static
  libraries: macOS, iPhoneOS, and iPhoneSimulator.
- The iOS simulator lane starts the real App in deterministic signed-out,
  locked, and unlocked roots without creating credentials, Keychain entries,
  tokens, or network traffic. It also traverses the safe Servers → Session →
  SFTP → Docker → Account path and asserts readable accessibility names for
  the critical roots and navigation controls. Public Release builds ignore
  that test-only launch state.
- Cross-client result and security parity is tracked in
  [PLATFORM_BEHAVIOR_ALIGNMENT_MATRIX.md](PLATFORM_BEHAVIOR_ALIGNMENT_MATRIX.md).
  It intentionally distinguishes data/security equivalence from native
  interaction differences such as iOS background limits and macOS windows.
- macOS lifecycle, window-close, sign-out, account-switch, and stale-callback
  rules run in the unsigned XCTest bundle. The macOS XCUITest target is also
  compiled by CI; executing its runner remains a signed release-candidate
  smoke because macOS testmanagerd cannot reliably attach to this app's
  hardened/Keychain configuration without a provisioning identity. Trigger
  the `Security Gates` workflow manually with `run_signed_macos_ui_smoke=true`
  on the provisioned self-hosted Apple-Silicon runner; it runs the real macOS
  UI target and verifies the produced application signature.
- Intel macOS is intentionally unsupported. Adding it requires a deliberate
  product decision, a Rust `x86_64-apple-darwin` build, universal or separate
  app packaging, checked-FFI symbol verification, and CI evidence. It must not
  be enabled merely by removing the `ARCHS` constraint.

## Evidence boundary

An unsigned iPhoneOS source build proves compilation and link compatibility;
it does not prove code-signing, installation, background behavior, or UI
behavior on a physical device. Those remain release and device-validation
evidence, respectively.

## Official-service transport boundary

- Requests to `server.orbitterm.com` require normal Apple system TLS trust,
  hostname validation, and a compiled SPKI SHA-256 public-key pin.
- The pin list supports overlap during a planned key rotation. A new key must
  be shipped alongside the current key before the server certificate changes.
- Self-hosted endpoints are HTTPS-only and require a host-specific explicit
  confirmation. They intentionally use Apple system trust and are never
  accepted by the official-host SPKI exception.
