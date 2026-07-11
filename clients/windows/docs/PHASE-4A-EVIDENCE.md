# Phase 4A Evidence: Local Server Asset Management

## Scope

Phase 4A prioritizes personal Windows client testing. It removes the production
runtime dependency on a hard-coded `example.com` asset and introduces local
server asset management that can evolve toward macOS parity without coupling UI
state to credential storage.

## Implemented

- Added `IServerAssetStore` and `ServerAssetRecord` in the application layer.
- Added `WindowsServerAssetStore`, which persists bounded JSON under the user's
  local OrbitTerm application data directory and writes through a temporary file
  before atomic replacement.
- Extended `AssetViewModel` with per-asset `CredentialId`, transport, and
  password fallback policy metadata.
- Extended `MainWindowViewModel` with load, new, save, and delete asset
  commands.
- Updated connection, terminal, SFTP, and session-end flows to use the current
  asset draft identifier and credential identifier.
- Updated the WinUI sidebar with asset action buttons and a server name field.
- Wired the app startup path to load local Windows assets.

## Safety Review

- Asset JSON does not contain passwords, private keys, passphrases, terminal
  content, or host-key trust material.
- Password material continues to use the credential vault abstraction.
- Deleting an asset also deletes its associated credential material.
- Invalid or malformed asset records are skipped on load.
- Asset count and asset JSON file size are bounded.

## Verification

- Local Windows-client toolchain: passed.
- Remote Windows-host full toolchain: passed.
- Non-UI project builds: passed.
- Security tests: passed, 58 total.
- Static security and release gates: passed.

## Remaining Work

- Add multi-tab workspace parity after the local asset foundation is stable.
