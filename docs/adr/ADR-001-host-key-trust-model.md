# ADR-001: SSH Host Key Trust Model

- Status: Accepted for foundation work
- Date: 2026-06-20
- Scope: Epic A1 pure Rust core only

## Context

OrbitTerm is an SSH client and operations workspace. It is not an SSH server, SSH gateway, or bastion data plane. A trustworthy client must authenticate the remote SSH server before sending a password, private-key signature, terminal input, or file-transfer data.

The current client handler in `orbit-core/src/lib.rs` accepts every server public key. This leaves SSH, SFTP, Docker, and monitoring sessions exposed to man-in-the-middle attacks and is a release blocker.

## Decision

OrbitTerm will implement an OpenSSH-style Known Hosts trust model with Trust On First Use (TOFU):

1. An unknown key requires explicit user confirmation before authentication.
2. A trusted key must match the stored host, port, algorithm, and key material.
3. A changed key is blocked by default and requires an explicit, separately presented replacement flow.
4. A revoked key is always blocked.
5. Unsupported or malformed records never become implicitly trusted.

This ADR establishes the model and the pure Rust parsing/matching foundation. **Epic A1 does not change the current production SSH connection behavior.** UI, C FFI, connection callbacks, and enforcement are deferred to Epic A2.

## Trust states

- `Unknown`: no applicable trusted record exists for the presented host, port, algorithm, and key.
- `Trusted`: host identity, algorithm, and key material match a normal Known Hosts record.
- `Changed`: the host and algorithm are known, but the presented key differs.
- `Revoked`: the presented key matches an `@revoked` record.
- `Unsupported`: an applicable record uses semantics not enforced by the current phase, such as `@cert-authority`.
- `Invalid`: the presented identity or key material is malformed.
- `Error`: verification could not complete because of an internal or storage failure.

## Host identity

`HostIdentity` separates the user-entered target from its normalized lookup identity:

- `original_host`: the trimmed target supplied by the caller.
- `normalized_host`: lowercase DNS name without a trailing dot, or canonical IP text.
- `port`: the effective TCP port.
- `lookup_host`: the normalized hostname or IP without port decoration.
- `lookup_token`: OpenSSH lookup token. Port 22 uses the bare host; non-default ports use `[host]:port`.

DNS names and IP addresses remain separate identities. A DNS connection does not inherit trust from the resolved IP, and an IP connection does not inherit trust from a DNS record.

## Known host record

`KnownHostRecord` retains:

- host patterns;
- marker;
- key algorithm;
- Base64 public-key blob;
- trailing comment;
- original source line;
- line number.

The future storage layer may add source metadata such as OrbitTerm local store or an explicitly imported system file. No platform path or file I/O is part of Epic A1.

## OpenSSH compatibility boundary

The foundation parser covers:

- ordinary hostnames;
- IPv4 and IPv6;
- `[host]:port` tokens;
- comma-separated host patterns;
- OpenSSH version 1 hashed hosts (`|1|salt|hash`);
- `@revoked`;
- recognition, but not trust enforcement, of `@cert-authority`;
- multiple host-key algorithms for one host;
- comments and empty lines;
- structured warnings for malformed lines while preserving those lines.

Wildcard and negated patterns are represented and matched without regular expressions. Hashed-host matching uses HMAC-SHA1 solely because that is the OpenSSH on-disk lookup format. It is not used as an SSH signature, host-key fingerprint, key exchange, or trust algorithm. Host-key fingerprints use SHA-256.

`@cert-authority` records are parsed but are not considered trusted until certificate validation has its own reviewed design and tests.

## Epic A1 implementation

- Host identity normalization.
- Trust-state and Known Hosts data structures.
- Known Hosts parser.
- SHA-256 OpenSSH-style fingerprint formatting.
- In-memory matching.
- Caller-supplied local file loading and atomic persistence.
- Explicit trusted-key add, remove, revoke, and confirmed replacement operations.
- Unit tests.

Epic A1 performs no network access, platform default-path discovery, cloud synchronization, UI work, or C FFI work.

## Local store and persistence

The store path is always supplied by the caller. The Rust core does not read or write the user's system `~/.ssh/known_hosts`, does not discover a platform path, and does not create a cloud-synchronized store. OrbitTerm's own application-support file is the intended default once A2 provides the platform path.

The default maximum file size is 1 MiB. This is sufficient for thousands of records while bounding memory use during parsing. Loading a missing file returns an empty store. Invalid UTF-8 and oversized files are fatal, structured errors; malformed individual lines are non-fatal warnings.

Saving uses a temporary file in the destination directory, followed by `write_all`, `flush`, file `fsync`, and rename. A failure before rename removes the temporary file and leaves the original destination untouched. Parent-directory `fsync` is attempted on Unix after a successful rename. On platforms where replacing an existing file with rename is unsupported, the operation fails without deleting the existing destination; a future platform adapter may provide an equivalent native atomic-replace primitive.

On Unix, new temporary files are created with mode `0600`, and the renamed destination inherits that mode. Loading an existing file with group or other permission bits records a warning but does not silently rewrite the file. Non-Unix platforms rely on the application sandbox or platform ACL; this phase does not claim Unix-style permission enforcement there.

## Serialization and preservation

Comments, blank lines, malformed lines, unsupported markers, and untouched valid records retain their original line content and order. Modified or newly created records use a canonical single-space representation. `@revoked` and `@cert-authority` markers are preserved and never converted to normal trust records.

Imported hashed-host records are preserved and can be matched. New trusted records use the normalized plaintext lookup token so that the user can inspect and manage them. Optional hashed output can be added later as an explicit privacy setting; this phase does not silently convert plaintext records or regenerate imported salts.

OpenSSH text records do not have reliable fields for first-seen or last-seen timestamps. OrbitTerm will not encode hidden metadata into comments. If A2 needs those timestamps, it will use a separate, versioned local metadata sidecar keyed by host identity and fingerprint.

Adding an already trusted key is idempotent. A different key for an existing host and algorithm returns a changed-key conflict and is never overwritten. A revoked key cannot be overridden by adding a trusted record. Key replacement requires an explicit API call containing the expected old key; A2 may call it only after user confirmation.

Normal deletion affects only exact trusted host patterns. It does not remove wildcard patterns, malformed lines, unsupported markers, certificate-authority records, or revoked records. Revocation deletion has a separate explicit API.

## Later phases

Epic A2 will add the connection enforcement and user decision flow. It will introduce an additive FFI contract and Apple UI only after the pure verifier and local store are stable. Epic A2/A3 will also cover MITM integration tests, algorithm policy, and RSA compatibility. ProxyJump is a later, independent Epic and every hop will require independent verification.

## Security principles

- Authentication must not begin before Host Key verification once A2 enforcement is enabled.
- Host Key changes are blocked by default.
- Revoked keys are never accepted.
- A key of one algorithm never implicitly trusts a different algorithm.
- Known Hosts are stored locally by default.
- Cloud synchronization is opt-in only.
- If synchronization is introduced, records must use the existing zero-knowledge encrypted transport, deletion tombstones, conflict handling, and an explicit security warning.
- Full public keys and credentials must not be written to diagnostic logs.

## Rollback

Epic A1 is additive. Rollback consists of removing the `security` module registration, its source files, and the three lightweight hashing dependencies. Because the production handler, C ABI, and Swift code are unchanged, no production data migration is required. A store file created only by tests or future A2 code remains standard Known Hosts text and can be safely retained or removed.

Epic A2 must remain separately revertible and must not reuse an implicit accept-all fallback when enforcement is enabled.

## Test strategy

Unit tests cover parsing, malformed-line isolation, host normalization, port separation, SHA-256 fingerprints, hashed-host matching, revoked-key precedence, algorithm separation, and certificate-authority non-trust. Later integration tests will use controlled OpenSSH and MITM fixtures to prove that authentication cannot follow an unverified key.
