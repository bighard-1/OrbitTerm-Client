use super::{
    reject_symlink, secure_atomic_json_write, validate_account_fingerprint, PlatformError,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const MAX_QUEUE_ITEMS: usize = 1_000;
const MAX_AUDIT_EVENTS: usize = 5_000;
const MAX_ENCRYPTED_BLOB_BYTES: usize = 6 * 1024 * 1024;
const MAX_DETAIL_CHARS: usize = 2_048;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncOperationKind {
    KeepLocalUpload,
    RestoreCloud,
    UseCloud,
    AcceptDeletion,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SyncAuditOutcome {
    Queued,
    Retrying,
    Failed,
    Completed,
    ManualRetry,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum QueuedSyncPayload {
    Upload {
        remote_id: u64,
        asset_id: Uuid,
        identity_fingerprint: Option<String>,
        encrypted_blob_base64: String,
        vector_clock: String,
    },
    Restore {
        asset_id: Uuid,
        device_id: Uuid,
        operation_id: Uuid,
        vector_clock: String,
    },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QueuedSyncOperation {
    pub id: Uuid,
    pub account_fingerprint: String,
    pub asset_id: Uuid,
    pub kind: SyncOperationKind,
    pub payload: QueuedSyncPayload,
    pub request_hash: String,
    pub local_fingerprint: Option<String>,
    pub created_at_unix_ms: u64,
    pub updated_at_unix_ms: u64,
    pub attempt_count: u32,
    pub next_retry_at_unix_ms: u64,
    pub last_error: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncAuditEvent {
    pub id: Uuid,
    pub queue_id: Option<Uuid>,
    pub account_fingerprint: String,
    pub asset_id: Uuid,
    pub kind: SyncOperationKind,
    pub outcome: SyncAuditOutcome,
    pub timestamp_unix_ms: u64,
    pub attempt_count: u32,
    pub detail: Option<String>,
}

#[derive(Clone, Debug)]
pub struct SyncOperationRepository {
    path: PathBuf,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncOperationDocument {
    version: u8,
    #[serde(default)]
    queue: Vec<QueuedSyncOperation>,
    #[serde(default)]
    audit: Vec<SyncAuditEvent>,
}

impl SyncOperationRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn enqueue(
        &self,
        account_fingerprint: &str,
        kind: SyncOperationKind,
        payload: QueuedSyncPayload,
        local_fingerprint: Option<String>,
        failure_reason: &str,
    ) -> Result<QueuedSyncOperation, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        validate_payload(kind, &payload)?;
        validate_optional_fingerprint(local_fingerprint.as_deref())?;
        let mut document = self.load_or_create()?;
        let request_hash = request_hash(account_fingerprint, &payload)?;
        if let Some(existing) = document
            .queue
            .iter()
            .find(|item| {
                item.account_fingerprint == account_fingerprint && item.request_hash == request_hash
            })
            .cloned()
        {
            return Ok(existing);
        }
        if document.queue.len() >= MAX_QUEUE_ITEMS {
            return Err(PlatformError::TooManySyncOperations);
        }
        let now = current_unix_ms()?;
        let item = QueuedSyncOperation {
            id: Uuid::new_v4(),
            account_fingerprint: account_fingerprint.to_owned(),
            asset_id: payload.asset_id(),
            kind,
            payload,
            request_hash,
            local_fingerprint,
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
            attempt_count: 0,
            next_retry_at_unix_ms: now,
            last_error: sanitized_detail(failure_reason),
        };
        document.queue.push(item.clone());
        append_audit(
            &mut document,
            audit_for(
                &item,
                SyncAuditOutcome::Queued,
                item.last_error.clone(),
                now,
            ),
        );
        self.save(&document)?;
        Ok(item)
    }

    pub fn pending(
        &self,
        account_fingerprint: &str,
    ) -> Result<Vec<QueuedSyncOperation>, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut items: Vec<_> = self
            .load_or_create()?
            .queue
            .into_iter()
            .filter(|item| item.account_fingerprint == account_fingerprint)
            .collect();
        items.sort_by_key(|item| (item.created_at_unix_ms, item.id));
        Ok(items)
    }

    pub fn next_due(
        &self,
        account_fingerprint: &str,
        now_unix_ms: u64,
    ) -> Result<Option<QueuedSyncOperation>, PlatformError> {
        Ok(self
            .pending(account_fingerprint)?
            .into_iter()
            .next()
            .filter(|item| item.next_retry_at_unix_ms <= now_unix_ms))
    }

    pub fn item(
        &self,
        account_fingerprint: &str,
        id: Uuid,
    ) -> Result<Option<QueuedSyncOperation>, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        Ok(self
            .load_or_create()?
            .queue
            .into_iter()
            .find(|item| item.account_fingerprint == account_fingerprint && item.id == id))
    }

    pub fn begin_attempt(
        &self,
        account_fingerprint: &str,
        id: Uuid,
    ) -> Result<QueuedSyncOperation, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        let now = current_unix_ms()?;
        let item = document
            .queue
            .iter_mut()
            .find(|item| item.account_fingerprint == account_fingerprint && item.id == id)
            .ok_or(PlatformError::SyncOperationNotFound)?;
        item.attempt_count = item.attempt_count.saturating_add(1);
        item.updated_at_unix_ms = now;
        let updated = item.clone();
        append_audit(
            &mut document,
            audit_for(&updated, SyncAuditOutcome::Retrying, None, now),
        );
        self.save(&document)?;
        Ok(updated)
    }

    pub fn mark_failed(
        &self,
        account_fingerprint: &str,
        id: Uuid,
        reason: &str,
    ) -> Result<QueuedSyncOperation, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        let now = current_unix_ms()?;
        let item = document
            .queue
            .iter_mut()
            .find(|item| item.account_fingerprint == account_fingerprint && item.id == id)
            .ok_or(PlatformError::SyncOperationNotFound)?;
        let detail = sanitized_detail(reason);
        item.updated_at_unix_ms = now;
        item.next_retry_at_unix_ms = now.saturating_add(backoff_ms(item.attempt_count));
        item.last_error = detail.clone();
        let updated = item.clone();
        append_audit(
            &mut document,
            audit_for(&updated, SyncAuditOutcome::Failed, detail, now),
        );
        self.save(&document)?;
        Ok(updated)
    }

    pub fn retry_now(
        &self,
        account_fingerprint: &str,
        id: Uuid,
    ) -> Result<QueuedSyncOperation, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        let now = current_unix_ms()?;
        let item = document
            .queue
            .iter_mut()
            .find(|item| item.account_fingerprint == account_fingerprint && item.id == id)
            .ok_or(PlatformError::SyncOperationNotFound)?;
        item.next_retry_at_unix_ms = now;
        item.updated_at_unix_ms = now;
        let updated = item.clone();
        append_audit(
            &mut document,
            audit_for(&updated, SyncAuditOutcome::ManualRetry, None, now),
        );
        self.save(&document)?;
        Ok(updated)
    }

    pub fn mark_completed(
        &self,
        account_fingerprint: &str,
        id: Uuid,
        detail: Option<String>,
    ) -> Result<(), PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        let index = document
            .queue
            .iter()
            .position(|item| item.account_fingerprint == account_fingerprint && item.id == id)
            .ok_or(PlatformError::SyncOperationNotFound)?;
        let item = document.queue.remove(index);
        append_audit(
            &mut document,
            audit_for(
                &item,
                SyncAuditOutcome::Completed,
                detail.and_then(|value| sanitized_detail(&value)),
                current_unix_ms()?,
            ),
        );
        self.save(&document)
    }

    pub fn record_completion(
        &self,
        account_fingerprint: &str,
        asset_id: Uuid,
        kind: SyncOperationKind,
        detail: Option<String>,
    ) -> Result<(), PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        append_audit(
            &mut document,
            SyncAuditEvent {
                id: Uuid::new_v4(),
                queue_id: None,
                account_fingerprint: account_fingerprint.to_owned(),
                asset_id,
                kind,
                outcome: SyncAuditOutcome::Completed,
                timestamp_unix_ms: current_unix_ms()?,
                attempt_count: 1,
                detail: detail.and_then(|value| sanitized_detail(&value)),
            },
        );
        self.save(&document)
    }

    pub fn audit(
        &self,
        account_fingerprint: &str,
        limit: usize,
    ) -> Result<Vec<SyncAuditEvent>, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut events: Vec<_> = self
            .load_or_create()?
            .audit
            .into_iter()
            .filter(|event| event.account_fingerprint == account_fingerprint)
            .collect();
        events.sort_by_key(|event| std::cmp::Reverse((event.timestamp_unix_ms, event.id)));
        events.truncate(limit.min(500));
        Ok(events)
    }

    fn load_or_create(&self) -> Result<SyncOperationDocument, PlatformError> {
        reject_symlink(&self.path)?;
        let document = match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let document = SyncOperationDocument {
                    version: 1,
                    ..Default::default()
                };
                self.save(&document)?;
                document
            }
            Err(error) => return Err(error.into()),
        };
        validate_document(&document)?;
        Ok(document)
    }

    fn save(&self, document: &SyncOperationDocument) -> Result<(), PlatformError> {
        secure_atomic_json_write(&self.path, document)
    }
}

impl QueuedSyncPayload {
    pub fn asset_id(&self) -> Uuid {
        match self {
            Self::Upload { asset_id, .. } | Self::Restore { asset_id, .. } => *asset_id,
        }
    }
}

fn audit_for(
    item: &QueuedSyncOperation,
    outcome: SyncAuditOutcome,
    detail: Option<String>,
    timestamp_unix_ms: u64,
) -> SyncAuditEvent {
    SyncAuditEvent {
        id: Uuid::new_v4(),
        queue_id: Some(item.id),
        account_fingerprint: item.account_fingerprint.clone(),
        asset_id: item.asset_id,
        kind: item.kind,
        outcome,
        timestamp_unix_ms,
        attempt_count: item.attempt_count,
        detail,
    }
}

fn append_audit(document: &mut SyncOperationDocument, event: SyncAuditEvent) {
    document.audit.push(event);
    if document.audit.len() > MAX_AUDIT_EVENTS {
        let excess = document.audit.len() - MAX_AUDIT_EVENTS;
        document.audit.drain(0..excess);
    }
}

fn validate_document(document: &SyncOperationDocument) -> Result<(), PlatformError> {
    if document.version != 1
        || document.queue.len() > MAX_QUEUE_ITEMS
        || document.audit.len() > MAX_AUDIT_EVENTS
        || document.queue.iter().any(validate_queue_item_invalid)
        || document.audit.iter().any(validate_audit_invalid)
    {
        Err(PlatformError::InvalidSyncOperations)
    } else {
        Ok(())
    }
}

fn validate_queue_item_invalid(item: &QueuedSyncOperation) -> bool {
    item.id.is_nil()
        || validate_account_fingerprint(&item.account_fingerprint).is_err()
        || item.asset_id.is_nil()
        || item.request_hash.len() != 64
        || !item
            .request_hash
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
        || validate_optional_fingerprint(item.local_fingerprint.as_deref()).is_err()
        || validate_payload(item.kind, &item.payload).is_err()
        || item.payload.asset_id() != item.asset_id
        || item
            .last_error
            .as_ref()
            .is_some_and(|value| value.chars().count() > MAX_DETAIL_CHARS || value.contains('\0'))
}

fn validate_audit_invalid(event: &SyncAuditEvent) -> bool {
    event.id.is_nil()
        || validate_account_fingerprint(&event.account_fingerprint).is_err()
        || event.asset_id.is_nil()
        || event.timestamp_unix_ms == 0
        || event
            .detail
            .as_ref()
            .is_some_and(|value| value.chars().count() > MAX_DETAIL_CHARS || value.contains('\0'))
}

fn validate_payload(
    kind: SyncOperationKind,
    payload: &QueuedSyncPayload,
) -> Result<(), PlatformError> {
    let valid_kind = matches!(
        (kind, payload),
        (
            SyncOperationKind::KeepLocalUpload,
            QueuedSyncPayload::Upload { .. }
        ) | (
            SyncOperationKind::RestoreCloud,
            QueuedSyncPayload::Restore { .. }
        )
    );
    if !valid_kind {
        return Err(PlatformError::InvalidSyncOperations);
    }
    let vector_clock = match payload {
        QueuedSyncPayload::Upload {
            remote_id,
            asset_id,
            identity_fingerprint,
            encrypted_blob_base64,
            vector_clock,
        } => {
            if *remote_id == 0
                || asset_id.is_nil()
                || encrypted_blob_base64.is_empty()
                || encrypted_blob_base64.len() > MAX_ENCRYPTED_BLOB_BYTES
                || identity_fingerprint
                    .as_ref()
                    .is_some_and(|value| value.len() > 512 || value.contains('\0'))
            {
                return Err(PlatformError::InvalidSyncOperations);
            }
            vector_clock
        }
        QueuedSyncPayload::Restore {
            asset_id,
            device_id,
            operation_id,
            vector_clock,
        } => {
            if asset_id.is_nil() || device_id.is_nil() || operation_id.is_nil() {
                return Err(PlatformError::InvalidSyncOperations);
            }
            vector_clock
        }
    };
    let clock = serde_json::from_str::<std::collections::HashMap<String, i64>>(vector_clock)
        .map_err(|_| PlatformError::InvalidSyncOperations)?;
    if vector_clock.len() > 64 * 1024
        || vector_clock.contains('\0')
        || clock.len() > 128
        || clock.values().any(|value| *value < 0)
    {
        Err(PlatformError::InvalidSyncOperations)
    } else {
        Ok(())
    }
}

fn validate_optional_fingerprint(value: Option<&str>) -> Result<(), PlatformError> {
    if value.is_some_and(|value| {
        value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit())
    }) {
        Err(PlatformError::InvalidSyncOperations)
    } else {
        Ok(())
    }
}

fn request_hash(
    account_fingerprint: &str,
    payload: &QueuedSyncPayload,
) -> Result<String, PlatformError> {
    let mut hasher = Sha256::new();
    hasher.update(b"OrbitTerm.Linux.SyncQueue.v1|");
    hasher.update(account_fingerprint.as_bytes());
    hasher.update(b"|");
    hasher.update(serde_json::to_vec(payload)?);
    Ok(format!("{:x}", hasher.finalize()))
}

fn backoff_ms(attempt_count: u32) -> u64 {
    const STEPS_SECONDS: [u64; 7] = [10, 30, 120, 300, 600, 900, 1_800];
    let index = attempt_count.saturating_sub(1) as usize;
    STEPS_SECONDS[index.min(STEPS_SECONDS.len() - 1)] * 1_000
}

fn sanitized_detail(value: &str) -> Option<String> {
    let cleaned: String = value
        .chars()
        .map(|character| {
            if character.is_control() && character != '\n' && character != '\t' {
                ' '
            } else {
                character
            }
        })
        .take(MAX_DETAIL_CHARS)
        .collect();
    (!cleaned.is_empty()).then_some(cleaned)
}

pub fn current_unix_ms() -> Result<u64, PlatformError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| PlatformError::SystemClockInvalid)?
        .as_millis()
        .try_into()
        .map_err(|_| PlatformError::SystemClockInvalid)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upload(asset_id: Uuid) -> QueuedSyncPayload {
        QueuedSyncPayload::Upload {
            remote_id: 7,
            asset_id,
            identity_fingerprint: Some("fixture".into()),
            encrypted_blob_base64: "ciphertext".into(),
            vector_clock: r#"{"linux":1}"#.into(),
        }
    }

    #[test]
    fn queue_deduplicates_and_retains_audit_after_completion() {
        let directory = tempfile::tempdir().unwrap();
        let repository = SyncOperationRepository::new(directory.path().join("operations.json"));
        let asset_id = Uuid::new_v4();
        let first = repository
            .enqueue(
                "001122aabbcc",
                SyncOperationKind::KeepLocalUpload,
                upload(asset_id),
                None,
                "offline",
            )
            .unwrap();
        let duplicate = repository
            .enqueue(
                "001122aabbcc",
                SyncOperationKind::KeepLocalUpload,
                upload(asset_id),
                None,
                "offline again",
            )
            .unwrap();
        assert_eq!(first.id, duplicate.id);
        assert_eq!(repository.pending("001122aabbcc").unwrap().len(), 1);
        let attempted = repository.begin_attempt("001122aabbcc", first.id).unwrap();
        assert_eq!(attempted.attempt_count, 1);
        let failed = repository
            .mark_failed("001122aabbcc", first.id, "network unavailable")
            .unwrap();
        assert!(failed.next_retry_at_unix_ms > failed.updated_at_unix_ms);
        repository.retry_now("001122aabbcc", first.id).unwrap();
        repository
            .mark_completed("001122aabbcc", first.id, Some("revision 9".into()))
            .unwrap();
        assert!(repository.pending("001122aabbcc").unwrap().is_empty());
        let audit = repository.audit("001122aabbcc", 20).unwrap();
        assert_eq!(audit.len(), 5);
        assert_eq!(audit[0].outcome, SyncAuditOutcome::Completed);
    }

    #[test]
    fn queue_is_account_partitioned_and_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("sync/operations.json");
        let repository = SyncOperationRepository::new(path.clone());
        repository
            .enqueue(
                "001122aabbcc",
                SyncOperationKind::KeepLocalUpload,
                upload(Uuid::new_v4()),
                None,
                "offline",
            )
            .unwrap();
        assert!(repository.pending("ffeeddccbbaa").unwrap().is_empty());
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn queue_recovers_after_reopen_without_persisting_auth_or_plaintext_secrets() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("sync/operations.json");
        let asset_id = Uuid::new_v4();
        let queue_id = {
            let repository = SyncOperationRepository::new(path.clone());
            repository
                .enqueue(
                    "001122aabbcc",
                    SyncOperationKind::KeepLocalUpload,
                    upload(asset_id),
                    Some("a".repeat(64)),
                    "connection refused",
                )
                .unwrap()
                .id
        };

        let repository = SyncOperationRepository::new(path.clone());
        let recovered = repository
            .item("001122aabbcc", queue_id)
            .unwrap()
            .expect("queued operation survives repository reopen");
        assert_eq!(recovered.asset_id, asset_id);
        let attempted = repository.begin_attempt("001122aabbcc", queue_id).unwrap();
        assert_eq!(attempted.attempt_count, 1);
        repository
            .mark_failed("001122aabbcc", queue_id, "temporary network failure")
            .unwrap();

        let repository = SyncOperationRepository::new(path.clone());
        let recovered = repository
            .item("001122aabbcc", queue_id)
            .unwrap()
            .expect("failed operation survives second reopen");
        assert_eq!(recovered.attempt_count, 1);
        assert_eq!(
            recovered.last_error.as_deref(),
            Some("temporary network failure")
        );
        assert!(recovered.next_retry_at_unix_ms >= recovered.updated_at_unix_ms + 10_000);
        repository.retry_now("001122aabbcc", queue_id).unwrap();
        assert!(repository
            .next_due("001122aabbcc", current_unix_ms().unwrap())
            .unwrap()
            .is_some());

        let contents = fs::read_to_string(path).unwrap();
        for forbidden in [
            "master_password",
            "access_token",
            "refresh_token",
            "private_key",
            "plaintext_password",
        ] {
            assert!(!contents.contains(forbidden));
        }
    }

    #[test]
    fn malformed_persistent_queue_fails_closed_without_overwrite() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("operations.json");
        fs::write(&path, br#"{"version":99,"queue":[],"audit":[]}"#).unwrap();
        let repository = SyncOperationRepository::new(path.clone());
        assert!(matches!(
            repository.pending("001122aabbcc"),
            Err(PlatformError::InvalidSyncOperations)
        ));
        assert!(fs::read_to_string(path)
            .unwrap()
            .contains(r#""version":99"#));
    }

    #[test]
    fn persistent_queue_refuses_symbolic_links() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.json");
        let path = directory.path().join("operations.json");
        fs::write(&target, br#"{"version":1,"queue":[],"audit":[]}"#).unwrap();
        symlink(target, &path).unwrap();
        let repository = SyncOperationRepository::new(path);
        assert!(matches!(
            repository.pending("001122aabbcc"),
            Err(PlatformError::SymlinkRefused)
        ));
    }
}
