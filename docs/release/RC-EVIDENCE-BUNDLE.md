# OrbitTerm Release Evidence Bundle

The final evidence bundle is a CI or release-management artifact. Generated
logs and signed binaries must not be committed to the application repository.

## Binding metadata

Record these values before running any gate:

```text
release_version:
release_tag:
commit_sha:
tree_sha:
build_number:
utc_timestamp:
operator_or_ci_run:
macos_version:
xcode_version:
rustc_version:
```

The worktree must be clean. Every artifact and log must come from the recorded
commit. If the commit changes, discard the bundle and create a new RC number.

## Bundle layout

```text
release-evidence/
  manifest.txt
  commit.txt
  git-status.txt
  toolchain.txt
  check-all.log
  openssh-smoke.log
  rust-tests.log
  apple-builds.log
  archive-metadata.txt
  symbol-check.log
  static-scan.log
  artifact-checksums.txt
  apple-client-sbom.cdx.json
  signing-verification.txt
  notarization-verification.txt
  release-notes.md
  launch-checklist.md
```

## Collection rules

1. Capture `git status --porcelain`, commit SHA, tree SHA, tag, and tool versions.
2. Run `scripts/security/check_all.sh` and the opt-in OpenSSH smoke without
   weakening flags or broadening allowlists.
3. Use Release archives built without `legacy-network-internal` or
   `ORBITTERM_INTERNAL_LEGACY_NETWORK`.
4. Store only sanitized logs. Never include private keys, passwords, tokens,
   Apple credentials, provisioning profiles, notary profiles, user known_hosts,
   Docker log bodies, or full remote commands.
5. Record SHA-256 checksums for every distributed artifact.
6. Generate and retain the CycloneDX SBOM from the exact locked SwiftPM and
   Cargo dependency inputs. It is provenance evidence, not an authorization to
   fetch unlocked dependencies.
7. Record `codesign`, Gatekeeper, archive validation, notarization, and stapling
   results without exporting signing identities or credentials.
8. Keep evidence outside the app bundle and outside source control. Publish it
   as a restricted CI/release artifact tied to the immutable tag.

## Retention

Retain the sanitized evidence bundle for at least 12 months and for at least two
superseding public releases, whichever is longer. Retain signing and
notarization receipts according to the organization's release-record policy.

## Current RC status

No final bundle may be generated from the current dirty worktree. The present
gate results are preflight evidence only and must be rerun after the RC commit
and tag are created.
