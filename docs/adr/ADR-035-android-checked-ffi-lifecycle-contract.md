# ADR-035: Android Checked FFI Lifecycle Contract

- Status: Accepted
- Date: 2026-07-27
- Scope: Android JNI boundaries for checked SSH, terminal, SFTP, Docker and monitor operations

## Decision

Android invokes native networking only through versioned checked FFI functions. Every response is a schema-versioned JSON envelope with a request ID, stable result kind and either typed data or a stable error object. Android must not use free-form native text, exception messages or `OK:/ERR:` prefixes to decide connection, trust or business state.

Each operation is scoped to an account generation and, when applicable, a verified base-session ID, terminal-channel ID or SFTP-session ID. The Android coordinator owns the generation check before state mutation. A response whose request ID, scope or generation no longer matches is discarded.

## Handle ownership and closure

| Handle | Created by | Owned by | Close rule | Late response rule |
| --- | --- | --- | --- | --- |
| SSH base session | checked connect | session coordinator | disconnect on explicit close, lock, logout or account switch | never recreates UI state |
| terminal channel | checked terminal open | terminal controller | retire output route before close; close is idempotent | retired channels are dropped at the bounded output pipeline |
| SFTP session / transfer | checked SFTP open | SFTP coordinator | cancel/close on scope invalidation | request ID and session scope are validated before UI update |
| Docker / monitor request | checked Docker or monitor call | feature coordinator | no persistent handle; cancellation invalidates generation | stale completion is ignored |

All native calls occur off the UI thread. Native callbacks must be bounded, non-blocking and exception-safe. The terminal callback is a 128-chunk / 16 KiB-per-chunk drop-newest pipeline; it records accepted, truncated, queue-full and retired-channel counters.

## Stable outcome contract

Success kinds are feature-specific (for example `connected`, `host_key_challenge`, `terminal_channel_opened`, `terminal_write_completed`). Errors carry stable snake-case `code`, localized `message_key`, bounded `detail_code`, `retryable`, request correlation and an optional challenge ID. Native source error text, paths, credentials, keys and tokens never cross the UI boundary.

Required terminal command validation includes schema version, request ID, expected kind and terminal channel ID. A repeated close maps `session_closed` / `session_not_found` to successful completion. Any malformed, uncorrelated or legacy-text response fails closed.

## Cancellation and timeout

Feature coordinators bind every request to an account scope and monotonically increasing operation generation. Lock, logout, account switch, disconnect and explicit cancel invalidate that generation before native close/cancel starts. Timeouts and cancellation are reported as stable result codes; a late native callback cannot reverse a newer UI state.

## Verification

Unit tests cover terminal queue saturation, truncation and retirement; typed terminal completion, malformed legacy text, repeated close and late response rejection. Core checked-FFI tests cover connected, host-key challenge/blocked, failure, cancellation and checked session gates. Android instrumentation and OpenSSH integration coverage are tracked in the P1 quality work.
