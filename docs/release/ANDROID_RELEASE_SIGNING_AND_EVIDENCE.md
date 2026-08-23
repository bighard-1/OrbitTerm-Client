# Android Production Signing and Evidence

The repository never contains a production keystore, alias, password or key
password. The normal local/CI Release gate intentionally produces unsigned
APK splits for structural verification only.

## Protected signing environment

Use the manual [Android Protected Release](../../.github/workflows/android-protected-release.yml)
workflow only from an immutable reviewed commit SHA or signed tag. Before it can
run, create the GitHub Environment `android-production-signing`, require
release-manager approval, and place the following values in that environment's
secrets (never in repository or organization-wide unprotected secrets):

```text
ORBITTERM_RELEASE_KEYSTORE_BASE64
ORBITTERM_RELEASE_KEYSTORE_PASSWORD
ORBITTERM_RELEASE_KEY_ALIAS
ORBITTERM_RELEASE_KEY_PASSWORD
```

`ORBITTERM_RELEASE_KEYSTORE_FILE` and
`ORBITTERM_REQUIRE_PRODUCTION_SIGNING` are workflow-owned runtime values. The
workflow decodes `ORBITTERM_RELEASE_KEYSTORE_BASE64` into the runner's temporary
directory with owner-only permissions, verifies every signing input is present,
then removes that file in an `always()` cleanup step. If one signing value is
present without the others, Gradle fails during configuration. If
`ORBITTERM_REQUIRE_PRODUCTION_SIGNING=true` is set without a complete signing
configuration, `:app:verifyReleaseSigning` fails before an artifact can be
accepted. No secret is written to source, generated metadata, logs or test
reports.

The protected workflow builds Rust `.so` files from source, runs the normal
Android Release gates, validates split APK signatures and ZIP contents, and
uploads signed APKs for 14 days plus a sanitized evidence artifact for 365 days.
It does not upload the keystore or any secret-bearing environment data.
It rejects mutable branch names, checks signed-tag provenance when a tag is
used, and requires a successful `Security Gates` workflow for the exact commit
before signing starts.

## Local non-production rehearsal

On 2026-07-28, the signing path was exercised with a two-day, temporary RSA
key created outside the repository. Both ABI split APKs were signed and
verified with that temporary certificate; debug signing was rejected and the
evidence collector correctly refused the dirty development worktree. The
temporary key was removed and local build outputs were restored to the normal
unsigned gate artifacts. This proves the plumbing only: it is not production
signing evidence and must not be used for distribution.

## Activation prerequisites

Before dispatching the protected workflow, merge and push the reviewed change,
wait for `Security Gates` to succeed on the exact immutable commit or signed
tag, and configure the protected GitHub Environment with its required reviewers
and four signing secrets. A release manager then dispatches the workflow with
that SHA or signed tag; no developer workstation needs access to the keystore.

## Isolated Release-like smoke package

`assembleSmoke` creates a minified, resource-shrunk package with application ID
`com.orbitterm.android.smoke`, signed only with the local Android debug key. It
is for a clean emulator snapshot and is never a distributable artifact. Its
separate storage prevents login, lock, theme and empty-state testing from
overwriting the installed production app or its account data.

`scripts/security/run_android_smoke_fixtures.sh` installs the matching smoke
APK, verifies locked, theme, empty-session, connection failure, Host Key
challenge, authentication failure, offline, sync conflict, Docker empty-list,
transfer queue and transfer-feedback fixtures, then removes the smoke package.
The fixtures are compiled from `src/smoke` only;
they never initialize account storage, DI, networking, SSH/native handles or a
production Activity.

## Evidence collection

After protected signing, from a clean, tagged worktree run:

```bash
scripts/security/collect_android_release_evidence.sh \
  /absolute/path/to/signed-artifacts \
  /absolute/path/to/restricted-evidence/android
```

The command refuses a dirty worktree, verifies APK signatures, rejects the
Android debug certificate, validates ZIP structure, and writes only commit/tree
identity, UTC time, checksum and signer-verification evidence. Store the output
outside source control with the restricted release evidence bundle.

Production signing, Play App Signing enrollment, and key custody remain
controlled release operations; they cannot be completed from a developer
workstation without the release authority.
