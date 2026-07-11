# Phase 1B Evidence: Windows Credential Vault

Date: 2026-06-30

## Scope

Phase 1B replaces the Windows credential vault placeholder with a platform-owned
secure storage implementation. The vault serializes credential material,
protects it with Windows user-scoped DPAPI, and stores only encrypted blobs in
the application's private LocalAppData directory.

## Implemented

- Replaced `WindowsCredentialVault` placeholder methods.
- Added `DpapiCredentialProtector` using `CryptProtectData` and
  `CryptUnprotectData`.
- Added `FileCredentialBlobStore` with temporary-file write and atomic replace.
- Added `CredentialVaultSerializer` for bounded JSON serialization.
- Added `CredentialMaterialPolicy` in Application for shared credential field
  limits.
- Added zeroing of plaintext buffers after protect/decrypt.
- Empty credentials delete the stored blob.

## Safety Properties

- UI and Application layers do not call DPAPI directly.
- DPAPI is isolated to the Windows platform project.
- Stored files contain encrypted blobs, not raw credential JSON.
- Credential identifiers must be non-empty GUIDs.
- Encrypted and plaintext payload sizes are bounded.
- DPAPI execution fails closed on non-Windows hosts.

## Verification

- `clients/windows/scripts/check_windows_toolchain.sh`
  - Windows static scans: pass.
  - Non-UI project builds: pass, 0 warnings, 0 errors.
  - `OrbitTerm.Security.Tests`: 40 passed, 0 failed.

## Known Limits

- Full WinUI/XAML compilation still requires a Windows x64 host.
- DPAPI runtime smoke requires a Windows x64 host.
