# OrbitTerm Android design system

## Cross-mobile information architecture

The iOS and Android clients use the same five personal-center groups, in this
order: Account & Security, Settings & Preferences, Operations, Help &
Information, Current Session. Platform-native controls may differ, but a
capability must not move to a different conceptual group on one platform.

Asset editors use one shared field order: identity metadata, endpoint and
transport, authentication, then SSH-only routing. Protocol selection changes
the suggested port without overwriting a user-entered custom port. Telnet is a
deliberately gated plaintext transport: it is hidden from normal connection
flows until the user explicitly enables it in Settings & Preferences.

Active mobile terminal workspaces reserve vertical space for the terminal.
Connection state belongs in the compact title area, multiple sessions use a
menu rather than a second full-width tab row, and the four workspace modules
use one compact segmented row.

This is the native Android visual contract for OrbitTerm. It applies to Compose
screens without changing SSH, SFTP, Docker, account, or sync behaviour.

## Genre and structure

- Genre: modern-minimal technical workbench.
- App structure: persistent five-destination bottom navigation, compact title
  bar, and route-owned working surfaces. There is no marketing footer.
- Primary axis: left-aligned operational information. Empty space separates
  tasks; it is never decoration.

## Theme

- Surfaces are opaque and elevation is conveyed by a small lightness step, not
  translucent brand colour or stacked shadows.
- The five iOS-aligned accents remain available: Sky Candy, Emerald Flow,
  Peach Dawn, Lavender Mist, and Glacier Mint.
- Accent colour identifies current selection, links, focus, and primary action;
  it does not fill large content areas.
- Dark and light mode preserve the selected hue while using contrast-safe text,
  outline, surface, and container roles.

## Type, space, and interaction

- Android system typography remains the UI face for legibility and platform
  consistency. Terminal content retains its independent monospace setting.
- Use the existing 4 dp rhythm: 4, 8, 12, 16, 24, 32. Section gaps are larger
  than in-card gaps.
- Titles are functional and left aligned. Metadata is quieter, never smaller
  than the Material accessibility defaults.
- Navigation, search, expansion, edit, destructive actions, loading, empty,
  and error states must keep a stable layout. Do not animate layout shifts.
- Touch targets follow Material 3 / Android accessibility guidance. Motion is
  reserved for platform state feedback and loading, with no decorative loops.

## Component voice

- Asset groups are a workbench index: one clear expansion affordance, count,
  and secondary overflow actions.
- Asset rows show identity, endpoint, connection state, and edit affordance in
  that order. Cards are single-level surfaces, never nested containers.
- Settings expose a preview when a visual choice has an observable result.

# OrbitTerm desktop visual system

## Scope and source of truth

This section is the shared visual contract for the native macOS, Windows and
Linux desktop clients. `shared/ui/desktop-visual-contract-v1.json` contains the
machine-readable dimensions and responsive rules. Platform-native title-bar
controls, system fonts, focus visuals, file pickers, accessibility providers,
keyboard modifier names and protected-storage affordances may differ; product
hierarchy, visual weight, information order and usable proportions may not.

The desktop genre is a compact professional operations workstation. Windows is
the structural reference because its pane protection and information density
best preserve terminal space. macOS is the material reference for colour depth,
focused authentication and restrained surfaces. Neither platform is copied as
a skin: every client implements one shared hierarchy with native controls.

## Responsive workstation geometry

- The window is a responsive canvas, not a collection of screenshot-sized
  rectangles. Width-sensitive elements use available width, a preferred ratio,
  and explicit minimum and maximum values.
- The supported minimum content size is 980 x 700 logical pixels. The preferred
  first-launch size is 1280 x 800. At the minimum size, the terminal remains at
  least 560 logical pixels wide.
- The asset pane prefers 300 logical pixels, may occupy 19–25% of the window,
  and is clamped to 220–320. The tool inspector prefers 328 logical pixels, may
  occupy 22–30%, and is clamped to 280–420.
- When the three expanded panes cannot preserve the terminal minimum, the tool
  inspector collapses first below 1180 logical pixels and the asset pane below
  980. A collapsed pane occupies zero layout width and is restored from a
  24–28 pixel edge affordance layered over the workbench.
- The top command lane is 36 logical pixels high. The overview lane is compact:
  34–40 logical pixels, with endpoint and six equal-width monitoring cards plus
  a fixed 54-pixel detail action. Cards expand and contract with the window.
- The terminal and tool inspector own all remaining height. Status or pre-input
  controls must not reserve an empty full-width row beneath the tool inspector.

## Fixed information order

1. Native window controls and square rounded OrbitTerm mark.
2. Add Server, Edit Credentials, Asset Management, Key Management, Port
   Forwarding, Batch Command, Settings, Account.
3. Current endpoint, CPU, memory, disk, download, upload, TCP latency, details.
4. Asset pane, tabbed terminal workspace, session tools.

The asset pane contains its heading, grouped assets and search. Asset groups are
collapsed by default. Synchronization status is visually aligned with the asset
pane but remains visible when that pane collapses. Session tools expose SFTP,
Docker and Snippets only while a compatible active session exists.

## Surfaces and interaction

- Use the shared 4/8/12/16/24 spacing rhythm. Workstation controls use 6–10
  pixel radii; cards use 10; dialogs use 14–20 according to native presentation.
- Prefer one-pixel semantic borders and a single surface lightness step. Shadows
  are reserved for detached dialogs, authentication and floating edge controls.
- The terminal surface is the visual anchor. Its command pre-input is a rounded
  bordered card with an icon, plain monospace field and icon-only send action.
- Authentication is a focused, centred task with a 480–560 pixel card. Account
  sign-in/registration, master-password setup/unlock and synchronization
  management are separate states and never appear as one crowded form.
- Settings use one scrollable sequence of named groups in the same order on all
  desktop platforms. A native list, group box or preferences row may be used,
  but a client must not invent a separate two-column information architecture.

## Theme parity

The five application palettes and light/dark/system modes share exact semantic
roles: page, chrome, panel, metric, input, border, primary text, secondary text,
accent, success, warning and danger. A platform may translate those colours to
native brushes, but may not substitute an unrelated system accent. Terminal
themes remain independent unless the user explicitly enables theme following.
