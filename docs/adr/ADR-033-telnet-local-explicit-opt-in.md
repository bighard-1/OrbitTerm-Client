# ADR-033: Telnet local explicit opt-in

## Status

Accepted for the post-RC3 compatibility update.

## Context

Public RC3 disabled Telnet because its availability was coupled to the internal legacy-network compilation condition. Some isolated networks still require Telnet for older switches, routers, and appliances, while OrbitTerm must continue to require checked SSH connections everywhere else. Requiring a backend policy would also prevent legitimate offline use.

## Decision

OrbitTerm ships one Apple client with Telnet compiled in but disabled by a new local preference that defaults to `false`. The old `orbitterm.enable.telnet` preference is ignored so an upgrade cannot silently enable the feature.

Telnet connection requires both:

1. explicit enablement in Settings after a plaintext-risk warning; and
2. confirmation of the exact server ID, normalized host, and port before the first connection.

Target confirmations remain local, are bounded, are not cloud-synchronized, and are cleared when Telnet is disabled. A changed host or port requires confirmation again. Disabling Telnet disconnects active Telnet sessions.

## Isolation

Telnet does not enable `legacyInternal`, legacy SSH, Quick Key deployment, SFTP, Monitor, Docker, or Batch. SSH failures never fall back to Telnet. The Release checked connection policy and Rust legacy fail-closed gate remain unchanged.

Credentials remain in Keychain at rest, but the UI clearly states that Telnet transmits credentials and terminal data without encryption or server identity verification. Telnet is intended only for trusted isolated networks or VPN-reachable legacy devices.

## Testing

- default-off and legacy-preference migration tests;
- enable plus per-target confirmation tests;
- host/port change re-confirmation tests;
- disable-and-forget tests;
- static scans for reviewed Telnet construction points and no legacy coupling;
- full Apple Debug/Release builds, existing checked FFI tests, security gates, and OpenSSH smoke.

## Rollback

The feature can be disabled locally without affecting SSH. A source rollback removes the UI and connection gate while leaving stored local preferences inert. RC3 remains immutable.
