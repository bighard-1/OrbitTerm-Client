# Windows Client Phases

## Phase 0A: Architecture and Safety Skeleton

Goal: establish the source tree, project boundaries, checked FFI wrapper shape,
static scans, and a minimal WinUI shell.

Exit criteria:

- Windows source tree exists under `clients/windows`.
- UI, application, platform, native bridge, and terminal layers are separate.
- Raw P/Invoke is isolated to `OrbitTerm.NativeBridge`.
- Static scans reject forbidden legacy ABI symbols.
- Checked envelope decoding has tests.
- WinUI shell is present but does not own business logic.

## Phase 0B: Windows Toolchain Bring-Up

Goal: run the skeleton on a Windows development machine or CI worker.

Exit criteria:

- .NET SDK and Windows App SDK restore successfully.
- Cross-platform non-UI projects build on macOS/Linux.
- `OrbitTerm.Security.Tests` passes.
- NuGet package versions are centrally pinned and lock files are generated.
- WinUI shell launches on Windows x64.
- `orbit-core` builds for Windows x64.
- Checked FFI smoke can load `orbit_core.dll`.

## Phase 0C: Checked FFI Contract and Connection State

Goal: make the Windows client consume checked FFI results through strong types
and application-owned connection states before building real UI workflows.

Exit criteria:

- NativeBridge decodes connected, Host Key challenge, blocked, and error
  outcomes without stringly typed UI decisions.
- Channel payloads reject non-HostKeyVerified generations.
- Application layer maps native outcomes into UI-safe connection states.
- Replace/accept-anyway style Host Key outcomes cannot become trust prompts.
- Tests cover connected, challenge, blocked, error, and channel generation
  invariants.

## Phase 0D: Verified Session and Terminal Channel Lifecycle

Goal: keep verified base sessions and terminal channel opening behind
application-owned lifecycle boundaries before building terminal UI.

Exit criteria:

- NativeBridge exposes terminal-open outcomes as strong types.
- Application layer registers only connected HostKeyVerified leases.
- Terminal opening requires a registered verified session.
- Terminal channel payloads must match the requested base session and PTY size.
- Tests cover registry replacement/removal, terminal channel mapping, and
  orchestrator gating.

## Phase 0E: Terminal Control Boundary

Goal: expose terminal write, resize, and close as application-owned operations
that require an active terminal lease.

Exit criteria:

- NativeBridge contains the legacy terminal control response parser.
- Application layer exposes UI-safe terminal control outcomes.
- Terminal writes, resizes, and closes require an active terminal session lease.
- Successful resize updates the registered terminal lease.
- Successful close removes the terminal lease.
- Backend terminal control error text does not flow into UI-facing results.

## Phase 1: Secure MVP

Goal: internal test build with SSH, Host Key verification, credential storage,
asset list, and one terminal tab.

Exit criteria:

- Unknown Host Key challenge is presented and can be persisted.
- Trusted host reconnects.
- Changed and revoked keys block.
- Credentials are stored through the Windows secure store.
- Terminal input/output is responsive under sustained output.
- No production code references legacy ABI symbols.

## Phase 1A: Host Key Trust Persistence

Goal: complete the unknown Host Key trust confirmation loop before wiring the
real UI workflow.

Exit criteria:

- Host Key challenge view models carry the checked request identifier.
- Host Key trust persistence is exposed through NativeBridge strong types.
- Application layer can persist only an active, trustable challenge.
- Persisted Host Key results must match the active challenge identity,
  algorithm, fingerprint, host, and port.
- Persistence failures remain structured as code/message-key results.
- User comments are bounded and stripped of control characters before crossing
  the native boundary.

## Phase 1B: Windows Credential Vault

Goal: replace the placeholder Windows credential store with a platform-owned
secure persistence boundary.

Exit criteria:

- Windows credential storage uses user-scoped DPAPI protection.
- Credential blobs are stored under the application private LocalAppData area.
- Plain credential bytes are zeroed after protection/decryption.
- Empty credentials remove the stored blob.
- Credential fields are bounded by shared application policy.
- Non-Windows hosts can still compile the platform project without executing
  DPAPI.

## Phase 1C: Connection and Terminal First Screen

Goal: provide a real WinUI first screen for the secure MVP without moving
business logic into XAML code-behind.

Exit criteria:

- Main window exposes asset selection, SSH connection input, Host Key trust
  action, terminal open/close, and command send controls.
- UI state and command eligibility live in a testable Presentation project.
- Password input is saved through `ICredentialVault` before connection.
- The App project wires NativeBridge, Platform, Application, and Presentation
  dependencies at launch.
- Presentation project builds on non-Windows hosts and has focused tests.
- Full XAML compilation remains a Windows-host validation item.

## Phase 1D: Terminal Output Callback Pipeline

Goal: route live terminal output from Rust callbacks into the Windows
presentation layer without exposing unmanaged pointers or raw callbacks to UI.

Exit criteria:

- NativeBridge registers `orbit_terminal_set_callback` once and copies callback
  bytes into managed buffers.
- Callback payloads are bounded and invalid callback inputs are ignored.
- Application layer accepts output only for active terminal leases.
- Terminal backlog updates are synchronized.
- Presentation receives output through application events and dispatches UI
  mutations onto the window thread.
- Tests cover active-channel delivery and closed/unknown channel rejection.

## Phase 1E: Windows Host Validation Harness

Goal: make real Windows validation repeatable and bounded before expanding the
MVP feature surface.

Exit criteria:

- Windows host validation refuses to run outside the configured test root.
- Existing toolchain checks are reused instead of duplicated.
- `orbit-core` builds for `x86_64-pc-windows-msvc`.
- Produced `orbit_core.dll` can be dynamically loaded on Windows x64.
- Required checked terminal exports are verified before full app validation.
- Full WinUI solution build is captured as a Windows-host gate.

## Phase 2: macOS Feature Parity

Goal: SFTP, Monitor, Docker, Batch, Snippets, sync, diagnostics, and Telnet
explicit opt-in.

Exit criteria:

- Feature workflows match macOS behavior and checked session constraints.
- Long-running transfers and monitor polling are cancellable.
- Diagnostics export is redacted.
- Telnet is locally opt-in and isolated from SSH.

## Phase 2A: Commercial Workbench Shell

Goal: evolve the first screen into a production-grade Windows workbench shell
without moving session, security, or terminal logic into XAML code-behind.

Exit criteria:

- Main window presents global connection state, selected asset context, terminal
  channel state, Host Key state, and session activity in a stable three-column
  workbench.
- Presentation layer owns all derived UI state for workspace, connection,
  security, terminal, and activity summaries.
- Existing connect, Host Key trust, terminal open/close, and command send
  commands remain the only UI action paths.
- Workbench state transitions are covered by presentation tests.
- Local Windows client toolchain checks pass.
- Full WinUI x64 solution builds on a Windows host.

## Phase 2B: Terminal Interaction Ergonomics

Goal: make the first terminal workspace feel like a practical daily-use client
while keeping interaction policy testable outside WinUI.

Exit criteria:

- Terminal input supports bounded command history.
- Up/down history navigation is exposed through presentation commands.
- Clear terminal is a presentation command and does not touch native sessions.
- Terminal input state and command history state are visible in the workbench.
- Keyboard handling in code-behind only dispatches to tested ViewModel commands.
- Presentation tests cover history, duplicate suppression, and clear behavior.

## Phase 2C: Terminal Paste Safety

Goal: protect the terminal input path from accidental multi-command paste and
unsafe control characters while keeping paste behavior predictable and
testable.

Exit criteria:

- Pasted command text is normalized before it reaches terminal write paths.
- Multi-line paste is converted into a single visible command line.
- Non-printing control characters are removed.
- Selection replacement and caret restoration remain stable in the UI bridge.
- Paste safety state is visible in the workbench runtime panel.
- Presentation tests cover sanitation, invalid selection clamping, and user
  status feedback.

## Phase 2D: Terminal Output Control

Goal: keep long-running terminal output responsive and give users predictable
copy and scroll controls without moving transcript policy into WinUI
code-behind.

Exit criteria:

- Terminal output has a bounded visible retention window.
- Hidden output count is exposed when older lines are pruned.
- Visible terminal transcript can be prepared for clipboard copy without
  logging or persisting output.
- Auto-scroll can be toggled by the user.
- WinUI code-behind only performs platform clipboard and scroll actions.
- Presentation tests cover retention, transcript preparation, and output
  status feedback.

## Phase 2E: Session Workflow Control

Goal: make the Windows workbench session lifecycle explicit and recoverable
without claiming native capabilities that are not yet exposed by the checked
Windows bridge.

Exit criteria:

- The application layer exposes a tested end-session workflow for verified
  session registration.
- Ending a session closes the active terminal channel first.
- Presentation state returns to a disconnected, no-terminal state.
- Reconnect attempts clean up any previous client-side session state first.
- UI exposes an End Session action without moving lifecycle policy into
  code-behind.
- Tests cover terminal cleanup, verified-state reset, and late output
  rejection.

## Phase 2F: SFTP Channel Entry

Goal: start macOS feature parity by exposing the checked SFTP channel workflow
in the Windows client without building unsafe or partial file operations.

Exit criteria:

- Application layer opens SFTP only from a registered verified session.
- SFTP payloads validate HostKeyVerified generation and bounded numeric ids.
- Presentation exposes SFTP open state and status.
- End Session clears SFTP state with the rest of the client session.
- WinUI exposes Open SFTP through command binding only.
- Tests cover application gating, ViewModel state, and session cleanup.

## Phase 2G: SFTP Browser Safety Shell

Goal: prepare the Windows SFTP browser experience around checked session state
and strict remote-path policy before enabling directory listing or file
transfer operations.

Exit criteria:

- SFTP browsing controls are enabled only after a checked SFTP channel is open.
- Remote paths must be absolute, bounded, and free of control characters,
  backslashes, and parent traversal.
- Path normalization is owned by the Presentation layer and covered by tests.
- UI status makes pending checked SFTP APIs explicit instead of presenting fake
  listing, upload, download, edit, or delete actions.
- Ending the session resets SFTP browser state with the rest of the session.
- Local and Windows-host validation gates pass after the change.

## Phase 2H: Checked SFTP Directory Listing

Goal: turn the SFTP browser shell into a real read-only directory listing
workflow through a checked Windows bridge without enabling higher-risk file
transfer or mutation operations.

Exit criteria:

- Rust exposes an additive `orbit_sftp_list_checked_v1` ABI that accepts only
  an existing checked SFTP channel id, a bounded absolute remote path, and a
  request id.
- SFTP list responses are wrapped in the checked Host Key envelope protocol.
- Directory entry payloads contain only metadata needed for display and are
  bounded before crossing into Windows.
- Windows NativeBridge, Application, and Presentation layers consume only the
  checked list ABI.
- UI lists directory entries read-only and does not expose upload, download,
  edit, delete, rename, mkdir, chmod, or create-file actions.
- Tests cover protocol validation, stable redacted errors, application lease
  mapping, and presentation listing behavior.
- Local, Windows-host, full repository, OpenSSH, sensitive-scan, and artifact
  cleanup gates pass after the change.

## Phase 2I: Checked SFTP Text Preview

Goal: add a read-only UTF-8 text preview workflow through the checked SFTP
bridge while keeping file mutation and transfer operations unavailable.

Exit criteria:

- Rust exposes an additive `orbit_sftp_read_text_checked_v1` ABI that accepts
  only an existing checked SFTP channel id, a bounded absolute remote path, and
  a request id.
- Text preview responses are bounded, UTF-8 only, and wrapped in the checked
  Host Key envelope protocol.
- Windows NativeBridge, Application, and Presentation layers consume only the
  checked text-read ABI.
- UI previews text read-only and does not expose save, upload, download,
  delete, rename, mkdir, chmod, or create-file actions.
- Tests cover protocol validation, stable redacted errors, application lease
  mapping, and presentation preview behavior.
- Local, Windows-host, full repository, OpenSSH, sensitive-scan, and artifact
  cleanup gates pass after the change.

## Phase 3: Commercial Release

Goal: signed, packaged, observable Windows client suitable for external users.

Exit criteria:

- MSIX package is signed.
- Update channel is defined.
- Accessibility, keyboard, high DPI, and localization smoke checks pass.
- Security evidence bundle is complete.
- Crash reporting and redacted diagnostics are available.

## Phase 3A: Release Candidate Gate

Goal: make Windows commercial release readiness repeatable before producing a
distributable signed package.

Exit criteria:

- Release candidate validation runs only on Windows x64 inside the authorized
  validation root.
- Release configuration is mandatory.
- WinUI release project properties are pinned for Windows App SDK, x64, MSIX
  tooling, and the supported Windows platform floor.
- A signing certificate thumbprint is required for distributable candidates;
  unsigned mode is explicit and limited to internal validation.
- Existing Windows host validation is reused in Release mode.
- Release native bridge output is verified after the gate.
- Validation cleans generated package publish directories and rejects
  source-tree TestResults, coverage, and publish leftovers.

## Phase 3B: MSIX Package Identity Skeleton

Goal: define a stable Windows package identity, manifest, and release asset
floor before enabling signed distributable package output.

Exit criteria:

- `OrbitTerm.App` declares a package manifest and explicit packaging policy.
- The MSIX manifest uses the OrbitTerm package identity, display name, version,
  Windows Desktop target family, and minimum supported Windows platform floor.
- Package capabilities are intentionally limited to internet client plus
  full-trust desktop execution.
- Required visual assets exist at the dimensions referenced by the manifest.
- Release candidate validation checks the package manifest and asset inventory.
- Local and Windows-host release candidate gates pass after the change.

## Phase 3C: Signed Package Build Contract

Goal: make signed Windows package creation explicit, certificate-bound, and
restricted to approved build/output roots before enabling external release.

Exit criteria:

- A dedicated signed package script exists and is included in static script
  inventory.
- Signed package output paths are restricted to the authorized Windows release
  root.
- Real package creation requires Release configuration and a signing
  certificate thumbprint.
- The signing certificate must exist, be unexpired, contain a private key, and
  match the package manifest publisher.
- Plan-only mode validates the workflow while refusing unsigned package output.
- Signed package creation reuses the release candidate gate before invoking
  package generation.
- Local and Windows-host plan validation gates pass after the change.

## Phase 3D: Update Channel Definition

Goal: define a commercial Windows update channel contract without enabling
external distribution before a production HTTPS endpoint exists.

Exit criteria:

- Stable channel metadata exists under the Windows release directory.
- Channel metadata matches the MSIX package identity, publisher, version, and
  minimum Windows platform floor.
- External distribution remains disabled until HTTPS appinstaller and package
  URIs are configured.
- Update channel metadata requires signed packages and HTTPS update transport.
- Static validation checks the update channel contract.
- Local and Windows-host plan validation gates pass after the change.

## Phase 3E: Redacted Diagnostics Bundle

Goal: provide a local diagnostics export contract that is useful for support
without leaking credentials, terminal content, known_hosts paths, commands, or
remote file paths.

Exit criteria:

- Application layer can build a versioned diagnostics JSON bundle.
- Runtime metadata includes product, version, channel, package identity, OS,
  architecture, and distribution state.
- Session metadata is limited to safe booleans, bounded host/key labels, and
  counts.
- Usernames, known_hosts paths, remote paths, and command text are redacted.
- Tests prove sensitive material does not appear in diagnostics JSON.
- Local Windows-client toolchain gates pass after the change.

## Phase 3F: Release Quality Smoke Gate

Goal: make accessibility, keyboard, high DPI, and localization release smoke
checks repeatable before external Windows distribution.

Exit criteria:

- Release quality metadata defines minimum window size, minimum text size,
  keyboard access, accessible-name, high-DPI, and localization expectations.
- Main window declares a practical minimum size.
- Icon-only keyboard history controls expose accessible names.
- Key lists and read-only preview areas expose accessible names.
- Static checks reject unmanaged raster `Image` usage until high-DPI variants
  are reviewed.
- Local and Windows-host toolchain gates pass after the change.

## Phase 3G: Security Evidence Bundle

Goal: make Windows commercial release evidence reviewable and machine-checked
before external distribution.

Exit criteria:

- A security evidence bundle index exists under the Windows release directory.
- The bundle references required phase evidence documents, release artifacts,
  validation scripts, and release gates.
- The bundle identity and version match the MSIX manifest.
- Static checks fail if Phase 3 evidence remains pending.
- Static checks verify required release artifacts and validation scripts exist.
- Local and Windows-host toolchain gates pass after the change.

## Phase 3H: Final Internal Release Readiness Gate

Goal: make the final Windows release state explicit, separating an approved
internal release candidate from an externally distributable commercial package.

Exit criteria:

- Release readiness metadata exists under the Windows release directory.
- Readiness metadata matches the MSIX package identity, update channel, and
  security evidence bundle.
- Internal release candidate readiness is explicitly approved.
- External commercial distribution remains blocked until a production signing
  certificate and HTTPS update endpoints are configured.
- Static checks validate release readiness on macOS/Linux.
- PowerShell checks validate release readiness on Windows hosts.

## Phase 3I: Full WinUI Host Build Gate

Goal: validate the Windows App XAML project on a real Windows host as part of
release readiness.

Exit criteria:

- Full WinUI solution build runs on the Windows host without the skip flag.
- XAML compiler errors are treated as release blockers.
- Unsupported WPF-style root `Window` size attributes are rejected.
- Release quality checks verify the WinUI code-side window size policy.
- Local cross-platform Windows toolchain gates pass after the fix.
- Remote Windows host toolchain gates pass with full WinUI build enabled.

## Phase 4A: Local Server Asset Management

Goal: make the Windows client practical for personal testing by replacing the
hard-coded sample endpoint with local server assets that can be loaded, edited,
selected, saved, and deleted.

Exit criteria:

- Application layer exposes a server asset store contract and serializable
  asset record without storing passwords in asset metadata.
- Windows platform layer persists assets to the user's local OrbitTerm data
  directory using bounded JSON and atomic file replacement.
- Presentation layer supports asset load, new draft, save/update, delete, and
  per-asset credential identifiers.
- Connection, terminal, SFTP, and session-end flows use the selected or draft
  asset identifier instead of a fixed sample asset.
- The Windows UI exposes asset editor actions and a name field while retaining
  the existing three-pane layout.
- Tests prove asset load/save/delete behavior, password separation, and
  per-asset credential cleanup.
- Local Windows-client toolchain gates pass after the change.

## Phase 4B: Workspace Tab Foundation

Goal: add a stable Windows workspace tab foundation that matches the macOS
client's tabbed workflow direction without mixing single-session runtime state
across multiple visible tabs.

Exit criteria:

- Presentation layer exposes workspace tabs with title, endpoint, asset
  identity, credential identity, and draft connection fields.
- Current connection draft changes synchronize into the active workspace tab.
- Switching tabs restores the selected tab's draft and clears password input.
- Opening and closing workspace tabs is available from the main window.
- Tab switching and tab closing are blocked while a verified session, host-key
  challenge, terminal channel, or SFTP channel is active.
- Tests prove tab draft preservation and active-runtime switch blocking.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4C: Workspace Tab Runtime Snapshot

Goal: make inactive Windows workspace tabs preserve their visible runtime state
so the next phase can move from single-active runtime to true per-tab sessions
without losing terminal, command, or SFTP context.

Exit criteria:

- Workspace tabs store terminal output, hidden terminal line count, command
  text, command history, and command history cursor.
- Workspace tabs store SFTP path, SFTP entries, SFTP browser status, SFTP
  operation status, and text preview state.
- Workspace tabs store visible status, security status, paste status, session
  action summary, and auto-scroll preference.
- Switching tabs saves the current tab snapshot before restoring the next tab.
- Passwords, leases, host-key challenges, and live channels remain outside tab
  snapshots.
- Tests prove terminal history, command history, SFTP draft path, and tab
  runtime snapshots are restored.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4D: Per-Tab Live Session Ownership

Goal: move Windows live session ownership from the window-level view model into
workspace tabs so verified sessions, terminal channels, SFTP channels, and
host-key challenges can be restored per tab.

Exit criteria:

- Workspace tabs own their own workspace identifier.
- Workspace tabs store their own verified connection state, host-key challenge,
  terminal lease, SFTP lease, and channel-open flags.
- Connect, trust-host, open-terminal, open-SFTP, terminal write, close-terminal,
  and end-session operations use the active tab's workspace and live leases.
- Switching tabs is allowed while another tab remains connected.
- Closing a tab with active runtime remains blocked until the session is ended.
- Terminal output is routed to the owning tab by workspace, server, and terminal
  channel identifiers.
- Tests prove active tab switching restores live session state and background
  terminal output does not leak into the visible tab.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4E: Safe Active Tab Close and Keyboard Entry Points

Goal: make Windows tab management safe and practical by providing an explicit
disconnect-and-close flow for active tabs and keyboard accelerators for common
tab actions.

Exit criteria:

- A normal close-tab command remains disabled while the selected tab owns an
  active verified session, host-key challenge, terminal channel, or SFTP channel.
- A separate disconnect-and-close command is enabled only for active tabs.
- Disconnect-and-close ends the selected tab's runtime through the existing
  session shutdown path before removing the tab.
- Disconnect-and-close resets to a clean draft when it closes the last tab.
- Tab open, close, and disconnect-close buttons expose keyboard accelerators.
- Tests prove active tabs cannot be closed directly but can be explicitly
  disconnected and closed.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4F: Menu and Command Entry Points

Goal: align Windows with the macOS command-oriented workflow by exposing common
workspace, session, terminal, SFTP, and asset actions through a native WinUI
menu bar.

Exit criteria:

- Main window has a native menu bar above the workstation.
- Workspace menu exposes new tab, close tab, disconnect-and-close tab, and
  indexed tab selection from 1 through 9.
- Session menu exposes connect, end session, and trust host.
- Terminal menu exposes open, close, clear, and copy transcript.
- SFTP menu exposes open SFTP, list directory, and preview text.
- Assets menu exposes new, save, and delete asset.
- Indexed tab selection is available through `Ctrl+1` through `Ctrl+9`.
- Tests prove indexed tab selection restores the intended tab draft and safely
  ignores out-of-range indexes.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4G: SFTP Browse Operations Foundation

Goal: make checked SFTP browsing practical on Windows by adding safe directory
navigation, selection, refresh, and read-only open behavior without connecting
legacy transfer or edit ABI calls.

Exit criteria:

- SFTP directory entries carry a normalized remote path, entry kind, and
  directory flag derived from checked directory-list payloads.
- The SFTP list view supports single selection and exposes an open-selected
  action.
- Opening a selected directory navigates into that directory through the
  checked list API.
- Opening a selected file previews it through the checked read-text API.
- Parent and refresh actions reuse the same path normalization and checked
  list API.
- Unsafe remote entry names are not converted into actionable paths.
- SFTP menu and runtime panel expose parent, refresh, and open-selected entry
  points.
- Tests prove command availability, directory navigation, file preview, and
  parent navigation.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4H: Diagnostics Copy Entry Point

Goal: make Windows practical for personal real-machine testing by exposing a
sanitized diagnostics bundle that can be copied from the app without exporting
terminal contents, credentials, raw commands, or remote file paths.

Exit criteria:

- Presentation layer can create a diagnostics JSON bundle from current runtime
  and session state.
- Diagnostics export uses the existing `DiagnosticsBundleFactory` redaction
  policy.
- Diagnostics include product, version, channel, OS, architecture, channel
  state, terminal/SFTP presence, host-key summary, and terminal line counts.
- Diagnostics redact username, Known Hosts path, last remote path, and last
  command.
- Windows UI exposes a Help menu entry for copying diagnostics.
- Runtime panel displays the latest diagnostics copy status.
- Tests prove diagnostics JSON is usable and does not contain passwords,
  usernames, raw commands, or raw remote paths.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4I: Checked Monitor Snapshot Entry Point

Goal: expose a safe, manual Windows Monitor refresh path backed by the checked
Monitor snapshot ABI so real-machine testing can inspect system metrics without
starting a legacy monitor flow or background polling loop.

Exit criteria:

- NativeBridge decodes and validates checked Monitor snapshot payloads.
- Application layer maps checked Monitor envelopes into a typed
  `MonitorSnapshotResult`.
- Monitor refresh requires an active verified SSH session and uses the verified
  base-session ID.
- Presentation layer exposes monitor status and a bounded metric summary.
- Workspace tabs preserve monitor status and summary when switching tabs.
- Session end resets monitor status and disables monitor refresh.
- Windows UI exposes a Monitor menu entry and Runtime panel refresh button.
- Tests prove monitor refresh is disabled before connect, succeeds after
  verification, displays bounded metrics, and resets after session end.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4J: Checked Docker List Entry Point

Goal: expose a safe, manual Windows Docker container list path backed by the
checked Docker ABI so real-machine testing can inspect containers without
enabling logs, actions, rename, update, or any legacy Docker flow.

Exit criteria:

- NativeBridge decodes and validates checked Docker container list payloads.
- Application layer maps checked Docker envelopes into a typed
  `DockerContainersResult`.
- Docker list requires an active verified SSH session and uses the verified
  base-session ID.
- Presentation layer exposes Docker status, summary, and a bounded container
  list.
- Workspace tabs preserve Docker status and container list when switching tabs.
- Session end resets Docker state and disables Docker refresh.
- Windows UI exposes a Docker menu entry and Runtime panel list button.
- Tests prove Docker list is disabled before connect, succeeds after
  verification, displays bounded containers, and resets after session end.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4K: Checked Docker Stats Snapshot Entry Point

Goal: expose a safe, manual Windows Docker stats refresh path backed by the
checked Docker stats ABI so real-machine testing can inspect read-only
container resource metrics without enabling logs, actions, rename, update, or
background polling.

Exit criteria:

- NativeBridge decodes and validates checked Docker stats payloads.
- Application layer maps checked Docker stats envelopes into a typed
  `DockerStatsResult`.
- Docker stats refresh requires an active verified SSH session and uses the
  verified base-session ID.
- Presentation layer exposes Docker stats summary and a bounded stats list.
- Workspace tabs preserve Docker stats summary and list when switching tabs.
- Session end resets Docker stats and disables stats refresh.
- Windows UI exposes a Docker stats menu entry and Runtime panel refresh
  button/list.
- Tests prove Docker stats refresh is disabled before connect, succeeds after
  verification, displays bounded read-only metrics, and resets after session
  end.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4L: Checked Docker Logs Read-Only Preview

Goal: expose a safe, manual Windows Docker log preview path backed by the
checked Docker logs ABI so real-machine testing can inspect a bounded tail of a
selected container without enabling Docker actions, rename, update, raw command
execution, or log export.

Exit criteria:

- NativeBridge decodes and validates checked Docker logs payloads.
- NativeBridge only allows bounded hex container IDs and bounded tail counts.
- Application layer maps checked Docker logs envelopes into a typed
  `DockerLogsResult`.
- Docker logs preview requires an active verified SSH session, a selected
  container, and the verified base-session ID.
- Presentation layer stores full container IDs internally while only displaying
  short IDs.
- Presentation layer exposes Docker log status and a read-only preview field.
- Workspace tabs preserve selected container and log preview state when
  switching tabs.
- Session end clears selected container and log preview state.
- Windows UI exposes a Docker logs menu entry and Runtime panel preview button.
- Tests prove logs are disabled until a container is selected, use a bounded
  tail count, display read-only preview text, and reset after session end.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4M: Guarded Docker Start Stop Restart Actions

Goal: expose a small, fixed Windows Docker action surface for personal testing
by enabling only checked start, stop, and restart actions on an explicitly
selected container without enabling remove, kill, pause, unpause, rename,
update, or raw action strings.

Exit criteria:

- NativeBridge calls `orbit_docker_action_checked_v1`.
- NativeBridge validates checked Docker action result payloads.
- NativeBridge only allows start, stop, and restart action tokens.
- Application layer maps checked Docker action envelopes into a typed
  `DockerActionResult`.
- Docker actions require an active verified SSH session, a selected container,
  and the verified base-session ID.
- Application rejects mismatched envelope kind, base session ID, container ID,
  or action token.
- Windows UI exposes Start, Stop, and Restart for the selected container.
- Windows UI does not expose remove, kill, pause, unpause, rename, update, or
  free-form action input.
- Tests prove actions are disabled until a container is selected and execute
  only the allowed action token.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4N: Docker Action State Reconciliation

Goal: make guarded Docker actions practical for real-machine testing by
refreshing the checked container list after a successful start, stop, or
restart action without expanding the Docker action surface.

Exit criteria:

- Start, stop, and restart still use the existing guarded action path.
- No remove, kill, pause, unpause, rename, update, or free-form action input is
  enabled.
- A successful Docker action triggers a checked container list refresh.
- The selected container is restored by full container ID after the refresh when
  it is still present.
- Docker summary reflects the refreshed checked list.
- Docker status distinguishes action success with refreshed containers from a
  refresh failure.
- Tests prove an action performs the action call and a follow-up checked list
  call, then restores selected container state.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.

## Phase 4O: Sanitized Runtime Diagnostics Expansion

Goal: make Windows real-machine testing easier to debug by expanding the copied
diagnostics bundle with sanitized Monitor, SFTP, and Docker runtime state
without exporting terminal contents, Docker logs, credentials, raw commands,
remote paths, or full container IDs.

Exit criteria:

- Diagnostics include Monitor status and summary.
- Diagnostics include SFTP status, operation status, and entry count.
- Diagnostics include Docker status, container summary, stats summary,
  container count, stats count, and whether a log preview exists.
- Diagnostics do not include Docker log text.
- Diagnostics do not include full Docker container IDs.
- Diagnostics continue to redact username, Known Hosts path, last remote path,
  and last command.
- Negative diagnostic counts are clamped to zero.
- Tests prove the new fields are exported and sensitive values remain absent.
- Local Windows-client toolchain gates pass after the change.
- Remote Windows-host full WinUI build passes after the change.
