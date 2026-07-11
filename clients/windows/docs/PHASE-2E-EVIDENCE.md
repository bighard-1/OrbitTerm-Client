# Phase 2E Evidence: Session Workflow Control

## Scope

Phase 2E adds an explicit Windows client session lifecycle action. The feature
ends the client-side verified session registration, closes any active terminal
channel first, and resets presentation state to disconnected.

## Implementation Notes

- `SessionOrchestrator.EndVerifiedSessionAsync` removes verified session
  registration through the application layer.
- The ViewModel owns the End Session workflow and closes an active terminal
  before ending the verified session.
- Reconnect attempts first end any existing client-side session or active
  terminal state.
- WinUI exposes End Session as a command-bound action only.
- The native bridge and Rust FFI are unchanged; no unavailable base-session
  disconnect API is implied.

## Validation

Completed validation for this phase:

- Local Windows client toolchain check passed.
- Local Windows security tests passed: 50 passed, 0 failed.
- Windows host validation stayed under the approved Windows test root.
- Windows host security tests passed: 50 passed, 0 failed.
- `orbit-core` Windows x64 MSVC build passed.
- `orbit_core.dll` dynamic load and checked terminal export smoke passed.
- Full WinUI solution build passed on Windows x64.
- Full repository security gate passed.
- OpenSSH release-candidate smoke passed.
- Sensitive information scan found no remote host address or credentials; only
  normal password field/control names and evidence text were matched.
- Build artifact cleanup check passed; no Windows `bin` or `obj` directories
  remained after cleanup.

## Review Notes

- Late terminal output is ignored after the terminal lease is cleared.
- Ending a pending Host Key review clears the review state without persisting
  trust.
- Clipboard, credential, and known_hosts handling are unchanged in this phase.
