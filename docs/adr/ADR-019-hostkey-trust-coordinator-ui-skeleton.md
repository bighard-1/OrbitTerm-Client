# ADR-019: Host Key Trust Coordinator and UI Skeleton

## Status

Accepted for A2.4b.

## Context

ADR-018 established Swift schema-v1 checked FFI DTOs, typed identifiers, and a canonical forwarding C header. Production Apple services still use legacy paths. Connecting `SessionManager` directly to the new ABI before defining and testing trust orchestration would mix credentials, UI, retries, stale responses, and service startup in one risky patch.

## Decision

### Checked client boundary

`CheckedFFIClient` is a `Sendable` asynchronous protocol for checked connect and accept-and-persist. Both operations explicitly carry a `HostKeyRequestID` and return a response wrapper containing the response request ID. This patch provides no production implementation and calls no C ABI.

`CheckedConnectInput` contains host, port, username, and an opaque `CredentialAccessReference`. It never contains a password, private key, passphrase, known-hosts path, or C pointer. Its descriptions redact the credential reference. A later production client must resolve the reference immediately through the credential provider rather than copying secrets into coordinator state.

### Coordinator

`HostKeyTrustCoordinator` is a `@MainActor ObservableObject`. The client may suspend away from the main actor, while all observable state transitions remain serialized for SwiftUI. States are strongly typed:

- idle;
- connecting;
- awaiting user decision;
- persisting;
- reconnecting;
- connected;
- blocked;
- failed;
- cancelled.

Unknown keys enter awaiting-decision. Changed, revoked, unsupported, and certificate-authority blocks remain blocked and never enter the trust path. Authentication, network, timeout, trust-store, save, protocol, and client failures remain distinct.

Trust acceptance first calls persist. Reconnect is created only after a matching persisted response for the same challenge. Save failure retains only the opaque flow context and challenge so Retry Save repeats persistence rather than connecting. Cancel invalidates the flow before any late response can update UI.

### Flow and request isolation

Every user connection flow receives a new `HostKeyFlowID`. Every initial connect, persist, retry, and reconnect receives a fresh `HostKeyRequestID`. State updates require all of the following:

- the flow is still active;
- the request is the current pending request;
- the response request ID matches;
- nested challenge IDs and request IDs match where applicable.

Stale and cancelled-flow responses are ignored and cannot advance authentication. Starting a new flow invalidates the old context. Separate coordinator instances do not share state.

Each client operation also races against an injectable coordinator timeout. Timeout cancels the child operation and enters a typed timeout failure; tests use a short deterministic boundary while production defaults to 20 seconds.

### Fake client

The XCTest-only `ScriptedCheckedFFIClient` is an actor. It can script connected, challenge, changed, revoked, structured errors, protocol failure, persistence success/failure, stale IDs, and delayed responses. It contains synthetic values only and performs no network or file I/O.

### Unknown UI

The challenge view displays host, port, algorithm, and selectable monospaced SHA256 fingerprint. It offers only Cancel and Trust This Host. It never auto-continues and has no Trust All action. Persisting has a visible loading state. Expired challenges disable trust and direct the user to restart the flow.

### Changed and revoked UI

Changed and revoked keys use distinct blocking language and an icon plus text rather than color alone. Changed displays previous and presented fingerprints when available. Revoked displays the presented fingerprint. Both expose only Close and Copy Fingerprints. Neither offers replacement, Accept Anyway, or accept-and-persist.

Unsupported and certificate-authority cases use the same fail-closed blocked container with unsupported-specific wording.

### Save error UI

Save failure exposes Retry Save and Cancel. It never displays the trust-store path. Retry Save repeats only persistence; reconnect remains conditional on a successful persisted response.

### Visual behavior

Views use semantic SwiftUI text styles, Dynamic Type, selectable monospaced fingerprints, warning icons, and a restrained orange tint rather than a large pure-red surface. Increased Contrast strengthens borders. No blur or material is required, so Reduce Transparency does not hide content or alter meaning.

### Known Hosts management

There is no Known Hosts management screen in this patch. Blocked views therefore do not show a dead navigation action. Replacement, deletion, and trust-record management remain future work.

## Credential and logging rules

The coordinator stores no credential material and logs neither complete JSON nor trust-store paths. UI contains no credentials. A future real client must fetch credentials from `CredentialVault` or another provider for each attempt, then release them after the synchronous FFI boundary.

## Why no network or SessionManager change

This patch is an isolated state-machine and presentation foundation. It deliberately has no real checked-client adapter, no C ABI invocation, no known-hosts write, and no changes to SessionManager, Terminal, SFTP, Monitor, Docker, or Batch behavior.

## Testing

The existing standalone macOS XCTest target compiles the protocol, coordinator, and presentation models with the actor fake. Tests cover direct connection, challenge/cancel, persist/reconnect, save failure/retry, changed/revoked, structured error classification, coordinator timeout, stale connect and persist responses, cancellation during connect and persistence, sequential challenges, parallel coordinators, redaction, expired challenges, and allowed UI actions.

iOS Simulator and macOS builds compile the SwiftUI skeleton. Tests perform no network or file writes.

## Follow-up

1. Add the Rust checked PTY additive ABI before terminal migration.
2. Implement a production `CheckedFFIClient` adapter and place SessionManager checked orchestration behind Debug/Internal gating.
3. Present this UI from the app-level flow and block SFTP, Monitor, and Docker until a verified base session exists.
4. Add Known Hosts management and replacement only as a separately reviewed design.

## Rollback

The coordinator, protocol, presentation models, views, and tests can be removed without runtime behavior change because no production service instantiates them. ADR-018 DTOs and canonical header forwarding remain valid independently.
