# OrbitTerm 1.0.1 RC.1 Launch Checklist

This checklist applies to the Apple public release only. Android SSH is not part
of this release candidate.

## Source and identity

- [ ] Create `release/orbitterm-p0-hostkey-rc1` from the reviewed security work.
- [ ] Confirm the worktree is clean before collecting evidence.
- [ ] Record the immutable commit SHA and create signed tag `v1.0.1-rc.1`.
- [ ] Confirm `MARKETING_VERSION=1.0.1` and approve or replace build `20260510`.
- [ ] Confirm bundle ID `com.orbitterm.app` is registered for macOS and iOS.
- [ ] Confirm the archive does not define `ORBITTERM_INTERNAL_LEGACY_NETWORK`.
- [ ] Confirm Rust is built without `legacy-network-internal`.

## Automated gates

- [ ] Run `scripts/security/check_all.sh` on the tagged commit.
- [ ] Run `ORBITTERM_RUN_OPENSSH_SMOKE=1 scripts/security/run_openssh_smoke.sh`.
- [ ] Archive the sanitized command logs in the RC evidence bundle.
- [ ] Record C Header and ABI symbol results.
- [ ] Record Swift Release object-reference scan results.
- [ ] Record artifact SHA-256 checksums.
- [ ] Record the locked-dependency CycloneDX SBOM from the evidence bundle.

## Packaging

- [ ] Produce macOS and iOS archives from the tagged commit.
- [ ] Resolve the iOS interface-orientation archive warning or accept it in the
      App Store validation record.
- [ ] Select the approved Apple Distribution and Developer ID identities.
- [ ] Export the iOS archive with a reviewed ExportOptions plist kept outside
      source control if it contains team-specific values.
- [ ] Sign the macOS app and DMG with the approved Developer ID identity.
- [ ] Submit the macOS artifact to Apple notarization.
- [ ] Staple and validate the notarization ticket.
- [ ] Verify Gatekeeper assessment on a clean macOS account or machine.
- [ ] Validate the iOS archive in App Store Connect without submitting it.
- [ ] Confirm no Android APK/AAB is attached to this release.
- [ ] Verify the official service TLS connection with the current SPKI pin;
      keep the current and next pin during any planned public-key rotation.

## Manual security and product QA

- [ ] First connection to an unknown host presents host, port, algorithm, and
      SHA-256 fingerprint without a Trust All action.
- [ ] Trust persists locally and reconnects successfully after app restart.
- [ ] Changed and revoked keys block without an accept-anyway action.
- [ ] Terminal command and disconnect/reconnect work.
- [ ] SFTP list, small upload, download, and delete work.
- [ ] Monitor displays a snapshot or a structured unsupported-platform state.
- [ ] Docker list, logs, and one safe action work if Docker is advertised.
- [ ] Batch runs on a verified target and rejects an unverified target.
- [ ] Telnet, Quick Key remote deploy, Docker rename/update, and checked-session
      terminal split remain unavailable.
- [ ] Offline, timeout, cancel, and known_hosts save failure are understandable.
- [ ] Host Key sheets pass VoiceOver, keyboard, Dynamic Type, and localization
      smoke checks.
- [ ] Diagnostic logs contain no credentials, private keys, commands, Docker
      log bodies, or local known_hosts paths.

## Release operations

- [ ] Approve the final release notes.
- [ ] Confirm rollback artifact and rollback owner.
- [ ] Confirm post-release monitoring and incident contacts.
- [ ] Complete the protected `Apple Protected Release` workflow from the exact
      reviewed commit SHA; do not promote a locally rebuilt artifact instead.
- [ ] Promote RC.1 without modifying its tag; any change becomes RC.2.
