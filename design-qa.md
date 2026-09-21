# OrbitTerm Linux desktop design QA

## Comparison target

- Source visual truth: `/Users/cwz/.codex/worktrees/820d/OrbitTerm-Client/artifacts/phase4-audit/01-workstation-before.png`, used as the same-machine baseline together with the desktop-shell hierarchy in `clients/windows/src/OrbitTerm.App/MainWindow.xaml`, `OrbitTerm/Features/Home/MainWorkstationView.swift`, and `OrbitTerm/Features/Home/WorkstationRightPanelView.swift`.
- Implementation screenshot: `/Users/cwz/.codex/worktrees/820d/OrbitTerm-Client/artifacts/phase4-audit/11-final-connected.png`.
- Combined comparison evidence: `/Users/cwz/.codex/worktrees/820d/OrbitTerm-Client/artifacts/phase4-audit/13-before-after-final.png`.
- Additional states: final empty workbench `10-final-empty.png`, credential editor `12-final-edit-credential.png`, login card `05-auth-card.png`, registration card `06-register-card.png`, port mapping `09-port-forward.png`.
- Viewport: 1280 × 720 desktop, light system theme, maximized window.
- Pixel dimensions: source 1280 × 720; implementation 1280 × 720; combined evidence 2560 × 720.
- CSS/device density: native GTK logical desktop pixels at the same GNOME display scale. No density normalization was required.
- State: real SSH connection to `Sync-Matrix-Primary`, Host Key verified, SFTP root directory loaded.

## Full-view comparison evidence

The combined image confirms that the implementation now follows the shared Apple/Windows workbench hierarchy: a complete command bar, a system overview band spanning the full three-column work area, asset navigation on the left, session content in the center, and context-only tools on the right. The former persistent black file-preview pane is absent, and the terminal receives the reclaimed vertical space.

## Focused-region evidence

Focused captures were used for the authentication flow because its typography, field rhythm, disclosure level, and mode switching are not readable enough in the full workbench comparison. `05-auth-card.png` and `06-register-card.png` confirm a bounded card, clear login/register modes, no exposed service hostname, invite-code and consent controls, and consistent native field styling. The connected workbench screenshot is sufficiently sharp to inspect the command bar, overview metrics, asset badges, terminal frame, SFTP toolbar, and panel dividers without additional crops.

## Required fidelity surfaces

- Fonts and typography: Adwaita Sans/Cantarell and JetBrains Mono/DejaVu Sans Mono fallbacks are consistent with native GNOME and the existing desktop hierarchy. Heading, caption, metric, endpoint, and terminal weights remain distinct; the localized `片段` label fits the narrow tool switcher without truncation.
- Spacing and layout rhythm: the overview band now spans all columns; the left/center/right proportions are stable at 1280 × 720; panel headers, list rows, terminal frame, and action strips share an 8–12 px rhythm. No persistent controls overlap or leave the viewport.
- Colors and tokens: all surfaces and semantic states use the existing GTK token file. Verified, warning, active, selected, disabled, and destructive states are distinguishable without introducing a new palette.
- Image quality and asset fidelity: the existing OrbitTerm RGBA rounded application icon is used directly in the header, desktop launcher, and Flatpak export. No substitute SVG, CSS drawing, emoji, or placeholder brand asset was introduced.
- Copy and content: the workbench copy is operational and concise; the authentication flow no longer exposes the synchronization hostname; security explanations remain available where a decision affects credentials, Host Key trust, plaintext Telnet, or local forwarding.
- Icons and affordances: native symbolic icons are used for all standard actions. Tooltips and accessible action names are present on icon-only controls. Panel collapse controls are located in their respective headers, matching the other desktop clients.
- States and interactions: empty, selected, connected, verified, login, registration, collapsed/expanded, SFTP-loaded, disabled actions, port-forward running/stopped, and batch-command result states were exercised.
- Accessibility: controls expose native AT-SPI roles and names; keyboard focus outlines are tokenized; destructive actions require confirmation. The Flatpak/VTE terminal does not expose a working AT-SPI component-focus method on this GNOME VM, so direct terminal typing was covered by key-sequence unit tests while the fallback input field was exercised end to end.

## Findings

No actionable P0, P1, P2, or P3 visual mismatch remains in the audited viewport and state. The former `Snippets` label truncation was resolved with the localized short label `片段`, and the credential editor now fits the 1280 × 720 desktop with an internal scroll area instead of extending past the work area.

## Comparison history

### Iteration 1 — blocked

- Earlier P1: system overview was embedded inside the center panel rather than spanning the three-column workbench.
- Earlier P1: the command bar omitted asset, key, port-forward, batch-command, and settings actions and exposed obsolete tool/sync toggles.
- Earlier P1: SFTP occupied permanent space with a black preview pane and lacked the complete mutation toolbar.
- Earlier P2: tools stayed visible without a usable session; login/register content was visually unbounded and disclosed infrastructure details.

Fixes made: moved the overview band above both paned containers; rebuilt the command bar in the Apple/Windows order; moved panel collapsing into panel headers; hid the tool region without an active SSH session; replaced the SFTP preview pane with a modal editor; added SFTP, Docker, snippets, port-forward, batch-command, settings, and authentication states.

Post-fix evidence: `10-final-empty.png`, `11-final-connected.png`, `05-auth-card.png`, `06-register-card.png`, and the same-size combined comparison `13-before-after-final.png`.

### Iteration 2 — passed with one minor follow-up

The revised 1280 × 720 implementation had no remaining P0/P1/P2 difference against the shared desktop-shell hierarchy. One P3 tool-label truncation remained.

### Iteration 3 — passed

The P3 tool-label truncation was removed, the credential editor gained complete password/private-key replacement with transactional keyring rollback, and the dialog height was rechecked at 1280 × 720. No actionable visual finding remains.

## Implementation checklist

- [x] Full desktop command order and actions.
- [x] Overview band above the three primary panels.
- [x] Context-only tools and header-owned panel collapse controls.
- [x] SSH/Telnet/RDP asset representation and batch import.
- [x] Login/register card and infrastructure-safe copy.
- [x] SFTP toolbar, mutation actions, transfer actions, and modal text editor.
- [x] Docker card/list/actions and modal logs.
- [x] Direct terminal key mapping plus verified fallback send path.
- [x] Native rounded app icon in Flatpak, app menu, and desktop launcher.
- [x] Release build, install, real SSH/SFTP, local tunnel, batch command, and accessibility action checks.

## Primary interactions tested

- 72 Rust tests passed; 0 failed; 2 opt-in isolated-account live tests remained ignored.
- Final installed Flatpak commit `146f8f9b854802626db79854932e55a7789cefb211a96c8e15805927d38197f2` connected to the real development asset and loaded 27 SFTP entries.
- Local forwarding opened `127.0.0.1:40717` through the verified SSH session and was then stopped.
- Batch execution returned exit status 0 and stdout `ORBITTERM_BATCH_OK`.
- The terminal fallback input returned `ORBITTERM_PREINPUT_OK` in the live VTE output.
- Both asset and tool panels collapsed and expanded using their native accessible actions.
- Login and registration modes were opened and visually captured.
- Native-app runtime log contained only expected virtual-GPU fallback warnings; no application panic or GTK critical error was observed.

final result: passed

---

## Phase 32 — cross-desktop empty-workspace alignment

### Comparison target

- macOS implementation: `/Users/cwz/.codex/worktrees/820d/OrbitTerm-Client/artifacts/phase32-visual-audit/03-macos-unified-empty-state-clean.png`.
- Linux implementation: `/Users/cwz/.codex/worktrees/820d/OrbitTerm-Client/artifacts/phase32-visual-audit/01-linux-unified-empty-state.png`.
- Windows source target: `clients/windows/src/OrbitTerm.App/MainWindow.xaml`, reviewed against the prior native 980 px, 1180 px, 1280 px, and maximized Phase 31 captures.
- State: authenticated/unlocked empty workspace with no saved asset and no live session.

### Findings and fixes

- macOS no longer exposes an ambiguous tab-strip `+` while the workspace is empty. Asset double-click, the asset context menu, and the documented keyboard shortcut remain the deterministic ways to create a session.
- Linux and macOS now use the same asset and session titles, descriptions, and action language. Infrastructure details are not disclosed in the empty state.
- Windows keeps its internal draft workspace object for view-model ownership but hides it from the tab strip until a connection or Host Key challenge actually starts.
- Windows collapses the redundant disabled empty-state terminal button and switches the narrow-width account entry to its icon-only form below 1080 px. The icon retains its tooltip and automation name.
- No new visual token, icon style, radius, palette, or platform-specific navigation pattern was introduced.

### Verification

- macOS Debug build passed with code signing disabled, then the authenticated in-memory UI state was captured from the current source.
- Linux formatting, strict Clippy, and the complete native quality gate passed: 111 tests passed and 3 explicitly isolated live-account tests remained ignored.
- Linux release and Flatpak packaging passed; Flatpak commit `32a3a6521f681ef9d61dd8da8f91e50a6641b4bbab68d4c239da273cf794df33` was installed and launched on Ubuntu 24.04.
- The Windows presentation contract is covered by a new view-model test for hidden draft tabs and the explicit transition to a visible session. Native Windows compilation remains a separate host gate; remote-control input translation prevented issuing the build command in this audit and is not represented as an application failure.
- GitHub Linux Client workflow #16 passed for commit `d155307c3afd8e6dd22f2f7df6a199ffe2266978`.

final result: passed
