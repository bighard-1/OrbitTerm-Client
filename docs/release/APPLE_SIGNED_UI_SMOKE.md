# macOS signed UI smoke lane

The ordinary Apple CI gate intentionally uses unsigned builds. It compiles the
macOS UI test target, but does not launch it: XCTest needs a signed host
application to attach to the hardened macOS process.

For a release candidate, trigger the `Security Gates` workflow manually and
enable `run_signed_macos_ui_smoke`. That job is intentionally scheduled only
on a self-hosted Apple-Silicon macOS runner with these labels:

```text
self-hosted, macOS, ARM64
```

Before triggering it, configure signing in that runner's Xcode environment:

- an approved OrbitTerm macOS signing identity;
- the matching provisioning settings and reviewed entitlements;
- the repository's locked source revision; and
- XcodeGen available on `PATH`.

The lane runs the real `OrbitTermmacOSUITests` launch-state smoke tests and
then verifies the generated `OrbitTerm.app` with `codesign --verify --deep
--strict`. It does not upload credentials, signing identities, diagnostic logs,
or built applications. Store those outside the repository according to the
release-evidence process.

The script is opt-in locally as well:

```bash
ORBITTERM_RUN_SIGNED_MACOS_UI_SMOKE=1 \
  scripts/security/run_macos_signed_ui_smoke.sh
```

Without the variable it exits successfully after printing that the signed lane
was skipped. This prevents an ordinary unsigned developer or hosted CI run
from falsely claiming macOS UI execution evidence.

For a local desktop build that must exercise login and Keychain-backed
credentials, use `scripts/install_macos_local_signed.sh`. Do not apply a bare
ad-hoc `codesign --sign -` after copying the bundle: doing so removes the
application's `keychain-access-groups` entitlement and causes Security.framework
to return `errSecMissingEntitlement` (`-34018`) during login. The local installer
fails closed unless the copied application retains the expected development
team and `BYZK354JK4.com.orbitterm.app` Keychain access group.
