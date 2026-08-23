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
