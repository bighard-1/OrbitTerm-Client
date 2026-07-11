# Final Personal Windows Build Evidence

## Build

- Source phase: Phase 5C after grouped WinUI startup correction.
- Configuration: Release, x64, self-contained, unpackaged WinUI.
- Native core: clean Windows MSVC Debug and Release builds passed.
- Output directory: `D:\\Macmini2\\OrbitTerm-Final-20260710-R2`.
- Desktop archive: `C:\\Users\\机房\\Desktop\\OrbitTerm-Windows-x64-20260710.zip`.
- Output: 499 files, 185,318,951 bytes.
- Archive: 71,638,084 bytes.

## Integrity

- `OrbitTerm.App.exe` SHA-256: `1BBA6197F74706F40ED095A4F070A0E151E30FE63515207B832689C076E83FB8`.
- `orbit_core.dll` SHA-256: `40375BF676E1F844627BA5DAA5E1C651BF86A1E31D4821710CAB5D351C343876`.
- Desktop ZIP SHA-256: `8475281ED0C716B587D0997C3C443AB2D5AA9DE7E1EB2BF953453C9A0F87E575`.

## Verification

- Rust tests: 287 passed, 0 failed, 2 environment fixtures ignored.
- Windows managed tests: 76 passed, 0 failed, 0 skipped.
- WinUI x64 Release/XAML build: passed.
- Windows static security and release gates: passed.
- R2 startup process remained alive for five seconds and was then stopped by the smoke harness.

## Use

This personal build is a self-contained folder archive, not an installer. Extract the complete ZIP to a local folder and run `OrbitTerm.App.exe` without moving individual runtime files out of that folder. A signed MSIX remains the correct future distribution format; an unsigned MSIX is intentionally not produced.
