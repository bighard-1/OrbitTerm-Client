# Apple privacy and release gate

This gate applies to the iOS and macOS OrbitTerm clients before a public
release candidate is accepted.

## Diagnostic data contract

Diagnostic exports contain only: timestamp, HTTP method, reviewed endpoint
category, status code, latency, retry attempt, and a reviewed failure category.
They never contain a host, URL, query, path, username, request ID, server error
text, command, terminal output, or credential. The generated temporary export
file inherits this same schema, uses a unique manager-owned name, is created
with owner-only file permissions where the platform supports them, is deleted
when the export view closes, and expires after fifteen minutes if sharing is
abandoned. It is shared only through the platform share sheet.

Diagnostic export failures use a generic recovery message; local file-system
errors and temporary paths are not rendered into the UI, diagnostic text, or
logs. No third-party crash-export SDK is linked by the Apple clients. Before
adding one, its event allowlist and attachment policy must be reviewed under
this gate; terminal output, command text, paths, host addresses, tokens,
private keys, and account identifiers are never eligible crash fields.

## Screen and clipboard policy

When an app becomes inactive or backgrounded, OrbitTerm covers the entire app
and asks sensitive editors to discard transient input. On iOS it also covers the
app during screen recording; on macOS its windows opt out of the window-sharing
API. Apple provides no public API that can prevent a user from taking a normal
system screenshot of a currently active app. Therefore secure fields, ephemeral
private-key input, and the inactive/recording cover are the enforceable product
controls; a release must not claim screenshot prevention beyond this platform
boundary.

Terminal output and Host Key fingerprints copied from OrbitTerm expire after 60
seconds only if the pasteboard has not changed. Passwords, tokens, and private
keys are rejected by the clipboard policy. This includes the macOS terminal
context menu, which routes its selected output through the same policy rather
than directly retaining it in `NSPasteboard`.

The macOS key-generation scratch directory is unique per operation, owner-only,
and removed in a `defer` path. Its process diagnostics are reduced to a typed
failure before entering the UI, so temporary paths cannot be displayed or
exported. Private-key import, generation, and save failures likewise provide a
generic recovery message rather than exposing a local file path or tool output.

## Provenance evidence

Run:

```bash
scripts/build_apple_core.sh
scripts/security/collect_apple_build_evidence.sh <evidence-directory>
```

The evidence directory contains the source commit, locked SPM/Cargo dependency
hashes, reviewed entitlement and privacy-manifest copies, and SHA-256 hashes
plus exported-symbol inventories for all Apple Rust static libraries.

## Public-release signing boundary

An unsigned archive is an internal RC artifact only. A public macOS release
requires a Developer ID signature, hardened runtime verification, notarization,
and a stapled ticket. An iOS public release requires the intended App Store,
TestFlight, or managed distribution signing profile. These credentials are not
stored in source control and must be supplied by the release environment.
