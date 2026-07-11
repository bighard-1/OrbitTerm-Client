# Phase 5A Evidence: Checked Batch Command Workflow

## Scope

Phase 5A connects the existing checked one-shot execution ABI to the Windows application and WinUI workbench. It adds a bounded per-tab Batch command and read-only result surface without introducing another SSH, shell, or credential path.

## Safety Boundary

- Batch execution requires the current workspace's active `HostKeyVerified` base-session lease.
- Windows calls only `orbit_exec_checked_v1`; no legacy exec, SFTP, raw channel, or reconnect fallback is used.
- Commands must be non-empty, contain no control characters, and be no larger than 8 KiB before crossing the native boundary.
- The core applies its existing 30-second default timeout and default 256 KiB stdout / 64 KiB stderr limits.
- Managed payload validation requires the matching base-session id, `host_key_verified` generation, successful exit, no timeout, no truncation, and bounded UTF-8 output.
- The asynchronous command disables itself while running, preventing duplicate concurrent execution from the same UI action.
- Command text and output are isolated to the current in-memory workspace tab. They are not written to assets, credentials, diagnostics, or local files.

## Review Findings Resolved

- The first output labels contained the substring `ERR:` and correctly triggered the legacy text-protocol scanner. Labels were changed to full human-readable names; the security scanner was not weakened or bypassed.
- Batch result state was added to workspace save/restore and session reset paths so output cannot appear in another tab or survive session teardown unexpectedly.
- Input validation is enforced in both presentation command eligibility and the native bridge boundary rather than relying on `MaxLength` in XAML.

## Verification

- Windows automated tests: 74 passed, 0 failed, 0 skipped.
- Windows WinUI x64 Release and XAML build: passed.
- Windows static security and release gates: passed after the review correction.
- XAML XML structure validation: passed.
- Existing Rust checked-exec implementation and limits were reused without modification.
- Remote validation was confined to `D:\\Macmini2\\phase-5a-validate`; the source archive was confined to `D:\\Macmini2\\orbitterm-phase-5a.zip`.

## Residual Boundary

The checked exec ABI is synchronous from the managed caller's perspective. The Rust core enforces a 30-second remote timeout, but this phase does not expose an interactive cancel button that can interrupt the native call earlier. Live execution against the user's actual SSH servers remains necessary to validate server-specific shell startup, locale, and command policy.
