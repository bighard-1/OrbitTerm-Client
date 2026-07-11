# Phase 4U Evidence: Self-Contained Portable Windows Client

## Scope

Phase 4U provides a certificate-free, unpackaged Windows client output for personal testing.

## Implementation

- `build_windows_portable.ps1` publishes an unpackaged, self-contained WinUI x64 Release output.
- The script builds `orbit-core` and explicitly adds `orbit_core.dll` to the portable directory.
- It fails if the output path already exists, the app executable is missing, or the native core DLL is missing.

## Safety Boundary

The portable output is a complete folder, not a single EXE. WinUI and Windows App SDK runtime files remain alongside `OrbitTerm.App.exe`; users must keep the folder intact. This removes the MSIX certificate-installation requirement without claiming commercial installer semantics.

## Verification

- Local static gate: passed.
- Local diff whitespace check: passed.
- Remote Windows static gate: passed.
- Remote Windows orbit-core x64 MSVC Debug and Release builds: passed.
- Remote Windows self-contained WinUI Release publish: passed.
- Portable output completeness check: passed with `OrbitTerm.App.exe` and `orbit_core.dll` present.
- Desktop portable client: copied as 499 files totaling 184,982,783 bytes.
