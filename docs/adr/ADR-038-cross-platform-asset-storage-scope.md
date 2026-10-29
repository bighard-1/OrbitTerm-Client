# ADR-038: Cross-platform asset storage scope

- Status: Accepted
- Date: 2026-09-14
- Applies to: macOS, iOS, Windows, Linux, Android

## Context

OrbitTerm needs two intentionally different asset lifetimes without making the
user infer them from login state:

- **Account synced**: metadata and credentials participate in the existing
  end-to-end encrypted configuration protocol and are visible only to their
  owning account after unlock.
- **Local only**: the asset remains on one device, is available while signed
  out, and never enters cloud inventory, upload queues, tombstones, conflicts,
  or recently deleted.

A visual-only selector is unsafe. If the persistence partition or mutation
queue ignores the selection, a nominally local asset can leak to the cloud, or
a nominally synced asset can silently disappear after sign-out.

## Decision

Every endpoint persists an explicit two-state `storageScope` value. Legacy
records are migrated according to their established product behavior:

- Apple and Android account-partitioned records become `accountSynced`.
- Android records from the pre-account unassigned partition become
  `localOnly` in a stable device partition.
- Windows retains its existing explicit scope and owner-account model.
- Linux records already present in per-account sync state remain synchronized;
  records absent from that index remain local. Once rewritten, the explicit
  value replaces this compatibility inference.

Local-only assets use a device partition independent of the active account.
The visible list is the union of that device partition and the active account
partition. A UUID collision is resolved in favor of the local record so a
remote pull cannot replace data the user intentionally kept off-account.

All protocols, including RDP, offer the same storage choice. Protocol type is
not a security boundary and must not silently force a storage scope.

## Mutation rules

| User action | Local persistence | Cloud operation |
| --- | --- | --- |
| Create/edit local-only | Device partition | None |
| Delete local-only | Remove device record and local credential | None |
| Create/edit synced | Active-account partition | Idempotent encrypted upsert |
| Delete synced | Remove account record and credential | Idempotent tombstone |
| Local-only to synced | Move to account partition | Encrypted upsert |
| Synced to local-only | Move to device partition | Tombstone old cloud copy |

Changing scope must be explicit in the editor and explained before save. A
client must not enable `accountSynced` without an authenticated account. Failed
network delivery leaves the durable operation queued; it must never roll back
the safe local copy or convert its scope implicitly.

## Presentation contract

All five clients use the same names and meaning:

- `随账户同步`: “凭据端到端加密后同步；退出账户时隐藏。”
- `仅此设备`: “未登录也可使用，不会上传。”

Lists and management views show a compact scope badge. Import defaults are
explicit: signed-in users default to account sync; signed-out users can create
only local assets. Backup/restore preserves scope and must never turn a local
asset into a synced asset without confirmation.

## Security invariants

1. Local-only UUIDs must not appear in sync inventory, upload, conflict, or
   recently-deleted requests. The sole exception is the durable tombstone
   created by an explicit synchronized-to-local conversion; it exists only to
   remove the prior cloud copy and is discarded after acknowledgement.
2. Synced records are inaccessible while signed out or under a different
   account, even if ciphertext and metadata remain cached locally.
3. Credentials stay in Keychain, DPAPI/Credential Locker, Secret Service, or
   Android Keystore; `storageScope` contains no secret material.
4. Account fingerprints are internal partition keys and are never presented as
   a username. User interfaces show a stored login name or a bounded identity
   claim instead.
5. Legacy or corrupt scope data fails closed for cloud access and never guesses
   a new account owner.

## Verification

Each release must cover create, edit, delete, sign-out, account switch,
offline retry, conversion in both directions, backup/restore, and remote pull
for SSH, Telnet where supported, and RDP. Cross-device tests verify that local
assets never arrive elsewhere and synced assets converge under a fixed UUID.
