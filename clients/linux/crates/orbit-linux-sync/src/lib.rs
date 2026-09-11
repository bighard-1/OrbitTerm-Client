use base64::engine::general_purpose::{STANDARD as BASE64, URL_SAFE_NO_PAD};
use base64::Engine;
use orbit_linux_domain::{AuthMethod, JumpHostConfiguration, ServerAsset, Transport};
use orbit_linux_platform::{CredentialMaterial, QueuedSyncPayload};
use reqwest::blocking::{Client, Response};
use reqwest::StatusCode;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroize;

pub const DEFAULT_SYNC_ENDPOINT: &str = "https://server.orbitterm.com";
const MAX_RESPONSE_BYTES: usize = 32 * 1024 * 1024;
const MAX_REMOTE_ITEMS: usize = 10_000;
const SYNC_PAGE_LIMIT: u16 = 100;

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
pub struct SyncTokens {
    pub access_token: String,
    pub refresh_token: String,
    #[serde(default)]
    pub account_scope: String,
}

impl SyncTokens {
    pub fn validate(&self) -> Result<(), SyncError> {
        if self.access_token.is_empty()
            || self.access_token.len() > 16 * 1024
            || self.refresh_token.len() > 16 * 1024
            || self.access_token.contains('\0')
            || self.refresh_token.contains('\0')
        {
            return Err(SyncError::InvalidToken);
        }
        Ok(())
    }
}

impl Drop for SyncTokens {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
        self.account_scope.zeroize();
    }
}

#[derive(Clone, Debug)]
pub struct CloudClient {
    client: Client,
    endpoint: &'static str,
}

pub struct KeepLocalAccountContext<'a> {
    pub remote: &'a RemoteConfig,
    pub master_password: &'a str,
    pub device_id: Uuid,
    pub account_scope: &'a str,
}

struct KeepLocalContext<'a> {
    remote: &'a RemoteConfig,
    master_password: &'a str,
    device_id: Uuid,
    account_scope: Option<&'a str>,
}

type LocalImportCandidate = (
    ServerAsset,
    CredentialMaterial,
    Option<(Uuid, CredentialMaterial)>,
);

impl CloudClient {
    pub fn production() -> Result<Self, SyncError> {
        let client = Client::builder()
            .https_only(true)
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(15))
            .user_agent("OrbitTerm-Linux/0.1.0")
            .build()?;
        Ok(Self {
            client,
            endpoint: DEFAULT_SYNC_ENDPOINT,
        })
    }

    #[cfg(test)]
    fn for_endpoint(endpoint: &'static str) -> Result<Self, SyncError> {
        let client = Client::builder().timeout(Duration::from_secs(2)).build()?;
        Ok(Self { client, endpoint })
    }

    pub fn login(&self, username: &str, password: &str) -> Result<SyncTokens, SyncError> {
        validate_login(username, password)?;
        let request = LoginRequest { username, password };
        let response: LoginData = self.post_json("/api/v1/auth/login", &request, None)?;
        let tokens = SyncTokens {
            access_token: response.access_token.or(response.token).unwrap_or_default(),
            refresh_token: response.refresh_token.unwrap_or_default(),
            account_scope: account_storage_identifier(username)?,
        };
        tokens.validate()?;
        Ok(tokens)
    }

    pub fn register(
        &self,
        username: &str,
        password: &str,
        invite_code: &str,
    ) -> Result<(), SyncError> {
        validate_login(username, password)?;
        let invite_code = invite_code.trim();
        if invite_code.is_empty()
            || invite_code.len() > 256
            || invite_code.chars().any(char::is_control)
        {
            return Err(SyncError::InvalidLogin);
        }
        let request = RegisterRequest {
            username: username.trim(),
            password,
            invite_code,
        };
        let _: serde_json::Value = self.post_json("/api/v1/auth/register", &request, None)?;
        Ok(())
    }

    pub fn pull_inventory(&self, tokens: &mut SyncTokens) -> Result<Vec<RemoteConfig>, SyncError> {
        tokens.validate()?;
        match self.get_inventory(&tokens.access_token) {
            Ok(items) => Ok(items),
            Err(SyncError::Unauthorized) if !tokens.refresh_token.is_empty() => {
                self.refresh(tokens)?;
                self.get_inventory(&tokens.access_token)
            }
            Err(error) => Err(error),
        }
    }

    pub fn pull_changes(
        &self,
        tokens: &mut SyncTokens,
        initial_cursor: u64,
    ) -> Result<SyncPullBatch, SyncError> {
        tokens.validate()?;
        let mut cursor = initial_cursor;
        let mut reset_recovered = false;
        let mut items = Vec::new();
        loop {
            let page = match self.get_sync_page(&tokens.access_token, cursor) {
                Ok(page) => page,
                Err(SyncError::Unauthorized) if !tokens.refresh_token.is_empty() => {
                    self.refresh(tokens)?;
                    self.get_sync_page(&tokens.access_token, cursor)?
                }
                Err(error) => return Err(error),
            };
            if page.reset_required {
                if reset_recovered {
                    return Err(SyncError::RepeatedCursorReset);
                }
                cursor = 0;
                reset_recovered = true;
                items.clear();
                continue;
            }
            if page.items.len() > MAX_REMOTE_ITEMS.saturating_sub(items.len()) {
                return Err(SyncError::InventoryTooLarge);
            }
            items.extend(page.items);
            if page.next_cursor < cursor {
                return Err(SyncError::CursorDidNotAdvance);
            }
            if !page.has_more {
                return Ok(SyncPullBatch {
                    items,
                    next_cursor: page.next_cursor,
                    reset_recovered,
                });
            }
            if page.next_cursor <= cursor {
                return Err(SyncError::CursorDidNotAdvance);
            }
            cursor = page.next_cursor;
        }
    }

    pub fn acknowledge(
        &self,
        tokens: &mut SyncTokens,
        device_id: Uuid,
        revision: u64,
    ) -> Result<u64, SyncError> {
        tokens.validate()?;
        let request = SyncAcknowledgementRequest {
            device_id: device_id.to_string(),
            revision,
            platform: "linux",
            client_version: env!("CARGO_PKG_VERSION"),
        };
        let response = match self.post_json(
            "/api/v1/config/sync/ack",
            &request,
            Some(&tokens.access_token),
        ) {
            Ok(response) => response,
            Err(SyncError::Unauthorized) if !tokens.refresh_token.is_empty() => {
                self.refresh(tokens)?;
                self.post_json(
                    "/api/v1/config/sync/ack",
                    &request,
                    Some(&tokens.access_token),
                )?
            }
            Err(error) => return Err(error),
        };
        let response: SyncAcknowledgementData = response;
        if response.acknowledged_revision != revision {
            return Err(SyncError::InvalidAcknowledgement);
        }
        Ok(response.acknowledged_revision)
    }

    pub fn keep_local(
        &self,
        tokens: &mut SyncTokens,
        local_asset: &ServerAsset,
        local_credential: &CredentialMaterial,
        remote: &RemoteConfig,
        master_password: &str,
        device_id: Uuid,
    ) -> Result<RemoteConfig, SyncError> {
        let payload = self.prepare_keep_local(
            local_asset,
            local_credential,
            remote,
            master_password,
            device_id,
        )?;
        self.execute_queued(tokens, &payload)
    }

    pub fn prepare_keep_local(
        &self,
        local_asset: &ServerAsset,
        local_credential: &CredentialMaterial,
        remote: &RemoteConfig,
        master_password: &str,
        device_id: Uuid,
    ) -> Result<QueuedSyncPayload, SyncError> {
        self.prepare_keep_local_internal(
            local_asset,
            local_credential,
            None,
            KeepLocalContext {
                remote,
                master_password,
                device_id,
                account_scope: None,
            },
        )
    }

    pub fn prepare_keep_local_for_account(
        &self,
        local_asset: &ServerAsset,
        local_credential: &CredentialMaterial,
        jump_host_credential: Option<&CredentialMaterial>,
        context: KeepLocalAccountContext<'_>,
    ) -> Result<QueuedSyncPayload, SyncError> {
        validate_account_scope(context.account_scope)?;
        self.prepare_keep_local_internal(
            local_asset,
            local_credential,
            jump_host_credential,
            KeepLocalContext {
                remote: context.remote,
                master_password: context.master_password,
                device_id: context.device_id,
                account_scope: Some(context.account_scope),
            },
        )
    }

    fn prepare_keep_local_internal(
        &self,
        local_asset: &ServerAsset,
        local_credential: &CredentialMaterial,
        jump_host_credential: Option<&CredentialMaterial>,
        context: KeepLocalContext<'_>,
    ) -> Result<QueuedSyncPayload, SyncError> {
        let KeepLocalContext {
            remote,
            master_password,
            device_id,
            account_scope,
        } = context;
        validate_remote_asset(remote, local_asset.id)?;
        let portable = portable_from_local(local_asset, local_credential, jump_host_credential)?;
        let mut plaintext = serde_json::to_vec(&portable)?;
        let remote_encrypted = BASE64
            .decode(remote.encrypted_blob_base64.as_bytes())
            .map_err(SyncError::from)?;
        let encrypted = if orbit_core::is_config_v2(&remote_encrypted) {
            let scope = account_scope.ok_or(SyncError::AccountScopeUnavailable)?;
            let mut root =
                orbit_core::derive_config_root_key_v2(master_password.as_bytes(), scope.as_bytes())
                    .map_err(|_| SyncError::EncryptFailed)?;
            let result = orbit_core::encrypt_config_v2(&root, &plaintext)
                .map_err(|_| SyncError::EncryptFailed);
            root.zeroize();
            result
        } else {
            orbit_core::encrypt_config(master_password.to_owned(), plaintext.clone())
                .map_err(|_| SyncError::EncryptFailed)
        };
        plaintext.zeroize();
        let encrypted = encrypted?;
        Ok(QueuedSyncPayload::Upload {
            remote_id: remote.id,
            asset_id: local_asset.id,
            identity_fingerprint: remote.identity_fingerprint.clone(),
            encrypted_blob_base64: BASE64.encode(encrypted),
            vector_clock: bump_vector_clock(&remote.vector_clock, device_id)?,
        })
    }

    pub fn restore_asset(
        &self,
        tokens: &mut SyncTokens,
        remote: &RemoteConfig,
        device_id: Uuid,
        operation_id: Uuid,
    ) -> Result<RemoteConfig, SyncError> {
        let payload = self.prepare_restore(remote, device_id, operation_id)?;
        self.execute_queued(tokens, &payload)
    }

    pub fn prepare_restore(
        &self,
        remote: &RemoteConfig,
        device_id: Uuid,
        operation_id: Uuid,
    ) -> Result<QueuedSyncPayload, SyncError> {
        let asset_id = remote_asset_id(remote)?;
        Ok(QueuedSyncPayload::Restore {
            asset_id,
            device_id,
            operation_id,
            vector_clock: bump_vector_clock(&remote.vector_clock, device_id)?,
        })
    }

    pub fn execute_queued(
        &self,
        tokens: &mut SyncTokens,
        payload: &QueuedSyncPayload,
    ) -> Result<RemoteConfig, SyncError> {
        let (asset_id, response) = match payload {
            QueuedSyncPayload::Upload {
                remote_id,
                asset_id,
                identity_fingerprint,
                encrypted_blob_base64,
                vector_clock,
            } => {
                let request = UploadConfigRequest {
                    id: Some(*remote_id),
                    // The server already resolves this existing record by its numeric ID.
                    // Omitting asset_id keeps uploads compatible with legacy records whose
                    // UUID was persisted with upper-case hex digits: UUIDs are
                    // case-insensitive, but older server releases compare this field as a
                    // case-sensitive string before applying the update.
                    asset_id: None,
                    identity_fingerprint: identity_fingerprint.clone(),
                    encrypted_blob_base64: encrypted_blob_base64.clone(),
                    vector_clock: vector_clock.clone(),
                };
                (
                    *asset_id,
                    self.post_authorized_with_refresh(tokens, "/api/v1/config/upload", &request)?,
                )
            }
            QueuedSyncPayload::Restore {
                asset_id,
                device_id,
                operation_id,
                vector_clock,
            } => {
                let request = AssetMutationRequest {
                    device_id: device_id.to_string(),
                    operation_id: operation_id.to_string(),
                    vector_clock: vector_clock.clone(),
                    confirmation: None,
                };
                let canonical = asset_id.to_string();
                let path = format!("/api/v1/config/assets/{canonical}/restore");
                let response = match self.post_authorized_with_refresh(tokens, &path, &request) {
                    // Swift's UUID string representation is upper-case, while Rust's is
                    // lower-case. Older server releases query historical asset IDs with
                    // case-sensitive SQL. Retry the same idempotent operation with the
                    // alternate UUID representation so persisted queues remain replayable.
                    Err(SyncError::IncrementalUnavailable) => {
                        let legacy = canonical.to_uppercase();
                        if legacy == canonical {
                            return Err(SyncError::IncrementalUnavailable);
                        }
                        let legacy_path = format!("/api/v1/config/assets/{legacy}/restore");
                        self.post_authorized_with_refresh(tokens, &legacy_path, &request)?
                    }
                    result => result?,
                };
                (*asset_id, response)
            }
        };
        validate_remote_asset(&response, asset_id)?;
        if matches!(payload, QueuedSyncPayload::Restore { .. })
            && response.state.as_deref().unwrap_or("active") != "active"
        {
            return Err(SyncError::InvalidMutationResponse);
        }
        Ok(response)
    }

    fn post_authorized_with_refresh<T: Serialize, R: DeserializeOwned>(
        &self,
        tokens: &mut SyncTokens,
        path: &str,
        body: &T,
    ) -> Result<R, SyncError> {
        tokens.validate()?;
        match self.post_json(path, body, Some(&tokens.access_token)) {
            Ok(response) => Ok(response),
            Err(SyncError::Unauthorized) if !tokens.refresh_token.is_empty() => {
                self.refresh(tokens)?;
                self.post_json(path, body, Some(&tokens.access_token))
            }
            Err(error) => Err(error),
        }
    }

    fn refresh(&self, tokens: &mut SyncTokens) -> Result<(), SyncError> {
        let request = RefreshRequest {
            refresh_token: &tokens.refresh_token,
        };
        let response: LoginData = self.post_json("/api/v1/auth/refresh", &request, None)?;
        let access = response.access_token.or(response.token).unwrap_or_default();
        if access.is_empty() || access.len() > 16 * 1024 || access.contains('\0') {
            return Err(SyncError::InvalidToken);
        }
        tokens.access_token.zeroize();
        tokens.access_token = access;
        if let Some(refresh) = response.refresh_token.filter(|value| !value.is_empty()) {
            tokens.refresh_token.zeroize();
            tokens.refresh_token = refresh;
        }
        tokens.validate()
    }

    fn get_inventory(&self, access_token: &str) -> Result<Vec<RemoteConfig>, SyncError> {
        let url = format!("{}/api/v1/config/pull", self.endpoint);
        let response = self.execute_with_retry(|| {
            self.client
                .get(&url)
                .bearer_auth(access_token)
                .header("Accept", "application/json")
                .send()
        })?;
        let payload: PullConfigData = decode_api_response(response)?;
        if payload.items.len() > MAX_REMOTE_ITEMS {
            return Err(SyncError::InventoryTooLarge);
        }
        Ok(payload.items)
    }

    fn get_sync_page(&self, access_token: &str, cursor: u64) -> Result<SyncPullData, SyncError> {
        let url = format!(
            "{}/api/v1/config/sync/pull?cursor={cursor}&limit={SYNC_PAGE_LIMIT}",
            self.endpoint
        );
        let response = self.execute_with_retry(|| {
            self.client
                .get(&url)
                .bearer_auth(access_token)
                .header("Accept", "application/json")
                .send()
        })?;
        decode_api_response(response)
    }

    fn post_json<T: Serialize, R: DeserializeOwned>(
        &self,
        path: &str,
        body: &T,
        access_token: Option<&str>,
    ) -> Result<R, SyncError> {
        let url = format!("{}{}", self.endpoint, path);
        let response = self.execute_with_retry(|| {
            let request = self
                .client
                .post(&url)
                .header("Content-Type", "application/json")
                .json(body);
            match access_token {
                Some(token) => request.bearer_auth(token).send(),
                None => request.send(),
            }
        })?;
        decode_api_response(response)
    }

    fn execute_with_retry<F>(&self, mut operation: F) -> Result<Response, SyncError>
    where
        F: FnMut() -> Result<Response, reqwest::Error>,
    {
        let mut last_error = None;
        for attempt in 0..3 {
            match operation() {
                Ok(response) if response.status().is_server_error() && attempt < 2 => {
                    thread::sleep(Duration::from_secs(1 << attempt));
                }
                Ok(response) => return Ok(response),
                Err(error) if (error.is_timeout() || error.is_connect()) && attempt < 2 => {
                    last_error = Some(error);
                    thread::sleep(Duration::from_secs(1 << attempt));
                }
                Err(error) => return Err(SyncError::Network(error)),
            }
        }
        Err(SyncError::Network(
            last_error.expect("retry loop records its network error"),
        ))
    }
}

fn decode_api_response<T: DeserializeOwned>(response: Response) -> Result<T, SyncError> {
    let status = response.status();
    if status == StatusCode::UNAUTHORIZED {
        return Err(SyncError::Unauthorized);
    }
    if status == StatusCode::NOT_FOUND || status == StatusCode::METHOD_NOT_ALLOWED {
        return Err(SyncError::IncrementalUnavailable);
    }
    if status.is_server_error() {
        return Err(SyncError::ServerRetryable(status.as_u16()));
    }
    let length = response.content_length().unwrap_or(0);
    if length > MAX_RESPONSE_BYTES as u64 {
        return Err(SyncError::ResponseTooLarge);
    }
    let mut bytes = Vec::with_capacity(length.min(MAX_RESPONSE_BYTES as u64) as usize);
    response
        .take((MAX_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_RESPONSE_BYTES {
        return Err(SyncError::ResponseTooLarge);
    }
    let envelope: ApiEnvelope<T> = serde_json::from_slice(&bytes)?;
    if !status.is_success() || !envelope.success {
        return Err(SyncError::Server(
            envelope.error.unwrap_or_else(|| format!("HTTP {status}")),
        ));
    }
    envelope.data.ok_or(SyncError::InvalidEnvelope)
}

fn validate_login(username: &str, password: &str) -> Result<(), SyncError> {
    if username.trim().is_empty()
        || username.len() > 255
        || username.chars().any(char::is_control)
        || password.is_empty()
        || password.len() > 16 * 1024
        || password.contains('\0')
    {
        return Err(SyncError::InvalidLogin);
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
struct ApiEnvelope<T> {
    success: bool,
    data: Option<T>,
    error: Option<String>,
}

#[derive(Serialize)]
struct LoginRequest<'a> {
    username: &'a str,
    password: &'a str,
}

#[derive(Serialize)]
struct RegisterRequest<'a> {
    username: &'a str,
    password: &'a str,
    invite_code: &'a str,
}

#[derive(Serialize)]
struct RefreshRequest<'a> {
    refresh_token: &'a str,
}

#[derive(Deserialize)]
struct LoginData {
    token: Option<String>,
    access_token: Option<String>,
    refresh_token: Option<String>,
}

#[derive(Deserialize)]
struct PullConfigData {
    items: Vec<RemoteConfig>,
}

#[derive(Debug, Deserialize)]
struct SyncPullData {
    items: Vec<RemoteConfig>,
    next_cursor: u64,
    has_more: bool,
    reset_required: bool,
}

pub struct SyncPullBatch {
    pub items: Vec<RemoteConfig>,
    pub next_cursor: u64,
    pub reset_recovered: bool,
}

#[derive(Serialize)]
struct SyncAcknowledgementRequest<'a> {
    device_id: String,
    revision: u64,
    platform: &'a str,
    client_version: &'a str,
}

#[derive(Deserialize)]
struct SyncAcknowledgementData {
    acknowledged_revision: u64,
}

#[derive(Serialize)]
struct UploadConfigRequest {
    id: Option<u64>,
    asset_id: Option<String>,
    identity_fingerprint: Option<String>,
    encrypted_blob_base64: String,
    vector_clock: String,
}

#[derive(Serialize)]
struct AssetMutationRequest {
    device_id: String,
    operation_id: String,
    vector_clock: String,
    confirmation: Option<String>,
}

pub fn account_fingerprint(access_token: &str) -> Result<String, SyncError> {
    let payload = access_token
        .split('.')
        .nth(1)
        .ok_or(SyncError::AccountIdentityUnavailable)?;
    let decoded = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| SyncError::AccountIdentityUnavailable)?;
    let claims: serde_json::Value =
        serde_json::from_slice(&decoded).map_err(|_| SyncError::AccountIdentityUnavailable)?;
    let uid = match claims.get("uid") {
        Some(serde_json::Value::String(value)) if !value.is_empty() => value.clone(),
        Some(serde_json::Value::Number(value)) => value.to_string(),
        _ => return Err(SyncError::AccountIdentityUnavailable),
    };
    let digest = Sha256::digest(format!("OrbitTerm.Sync.Account.v1|{uid}").as_bytes());
    Ok(digest[..6]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub fn account_storage_identifier(username: &str) -> Result<String, SyncError> {
    let canonical = username.trim().to_lowercase();
    if canonical.is_empty() || canonical.len() > 255 || canonical.chars().any(char::is_control) {
        return Err(SyncError::AccountScopeUnavailable);
    }
    Ok(Sha256::digest(canonical.as_bytes())
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[derive(Clone, Debug, Deserialize)]
pub struct RemoteConfig {
    pub id: u64,
    pub asset_id: Option<String>,
    pub encrypted_blob_base64: String,
    pub vector_clock: String,
    #[serde(default)]
    pub identity_fingerprint: Option<String>,
    pub state: Option<String>,
    pub server_revision: Option<u64>,
    #[serde(default)]
    pub updated_at: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortableServerConfig {
    pub id: String,
    #[serde(default)]
    pub credential_id: String,
    pub name: String,
    #[serde(default)]
    pub group: String,
    #[serde(default)]
    pub tags: Vec<String>,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: String,
    #[serde(default = "default_transport")]
    pub transport: String,
    #[serde(default)]
    pub network_device_profile: String,
    #[serde(default)]
    pub allow_password_fallback: bool,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key_content: String,
    #[serde(default)]
    pub private_key_passphrase: String,
    #[serde(default)]
    pub key_reference: String,
    #[serde(default)]
    pub saved_at_unix: u64,
    #[serde(default)]
    pub jump_host: Option<PortableJumpHostConfiguration>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortableJumpHostConfiguration {
    #[serde(default)]
    pub credential_id: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: String,
    #[serde(default)]
    pub allow_password_fallback: bool,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub private_key_content: String,
    #[serde(default)]
    pub private_key_passphrase: String,
}

fn default_transport() -> String {
    "ssh".into()
}

pub struct ImportCandidate {
    pub asset: ServerAsset,
    pub credential: CredentialMaterial,
    pub jump_host_credential: Option<(Uuid, CredentialMaterial)>,
    pub remote: RemoteConfig,
}

pub struct SyncConflict {
    pub asset_id: Uuid,
    pub local: ServerAsset,
    pub remote: ImportCandidate,
    pub reason: String,
}

pub struct TombstoneConflict {
    pub asset_id: Uuid,
    pub local: ServerAsset,
    pub remote: RemoteConfig,
    pub restore_operation_id: Uuid,
    pub restorable: bool,
    pub reason: String,
}

pub struct SyncFailureSummary {
    pub asset_id: Option<Uuid>,
    pub reason: String,
}

pub struct SyncPreview {
    pub candidates: Vec<ImportCandidate>,
    pub satisfied: Vec<RemoteConfig>,
    pub remote_active: usize,
    pub auxiliary_records: usize,
    pub tombstones: usize,
    pub conflicts: Vec<SyncConflict>,
    pub tombstone_conflicts: Vec<TombstoneConflict>,
    pub deferred: Vec<Uuid>,
    pub failures: Vec<SyncFailureSummary>,
}

impl SyncPreview {
    pub fn unresolved_count(&self) -> usize {
        self.conflicts.len()
            + self.tombstone_conflicts.len()
            + self.deferred.len()
            + self.failures.len()
    }
}

pub fn build_pull_preview(
    remote: Vec<RemoteConfig>,
    local_assets: &[ServerAsset],
    applied_revisions: &HashMap<Uuid, u64>,
    master_password: &str,
) -> Result<SyncPreview, SyncError> {
    build_pull_preview_internal(
        remote,
        local_assets,
        applied_revisions,
        &std::collections::HashSet::new(),
        master_password,
        None,
    )
}

pub fn build_pull_preview_for_account(
    remote: Vec<RemoteConfig>,
    local_assets: &[ServerAsset],
    applied_revisions: &HashMap<Uuid, u64>,
    master_password: &str,
    account_scope: &str,
) -> Result<SyncPreview, SyncError> {
    validate_account_scope(account_scope)?;
    build_pull_preview_internal(
        remote,
        local_assets,
        applied_revisions,
        &std::collections::HashSet::new(),
        master_password,
        Some(account_scope),
    )
}

pub fn build_pull_preview_with_deferred(
    remote: Vec<RemoteConfig>,
    local_assets: &[ServerAsset],
    applied_revisions: &HashMap<Uuid, u64>,
    deferred_assets: &std::collections::HashSet<Uuid>,
    master_password: &str,
) -> Result<SyncPreview, SyncError> {
    build_pull_preview_internal(
        remote,
        local_assets,
        applied_revisions,
        deferred_assets,
        master_password,
        None,
    )
}

pub fn build_pull_preview_with_deferred_for_account(
    remote: Vec<RemoteConfig>,
    local_assets: &[ServerAsset],
    applied_revisions: &HashMap<Uuid, u64>,
    deferred_assets: &std::collections::HashSet<Uuid>,
    master_password: &str,
    account_scope: &str,
) -> Result<SyncPreview, SyncError> {
    validate_account_scope(account_scope)?;
    build_pull_preview_internal(
        remote,
        local_assets,
        applied_revisions,
        deferred_assets,
        master_password,
        Some(account_scope),
    )
}

fn build_pull_preview_internal(
    remote: Vec<RemoteConfig>,
    local_assets: &[ServerAsset],
    applied_revisions: &HashMap<Uuid, u64>,
    deferred_assets: &std::collections::HashSet<Uuid>,
    master_password: &str,
    account_scope: Option<&str>,
) -> Result<SyncPreview, SyncError> {
    if master_password.is_empty() || master_password.len() > 16 * 1024 {
        return Err(SyncError::InvalidMasterPassword);
    }
    let local_by_id: HashMap<Uuid, &ServerAsset> =
        local_assets.iter().map(|asset| (asset.id, asset)).collect();
    let mut newest = HashMap::<Uuid, RemoteConfig>::new();
    let mut tombstones = 0;
    let mut auxiliary_records = 0;
    let mut failures = Vec::new();

    for item in remote {
        let asset_id = item
            .asset_id
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok());
        let Some(asset_id) = asset_id else {
            let state = item.state.as_deref().unwrap_or("active");
            if item.id == 0
                || item.server_revision.is_none()
                || state != "active"
                || validate_vector_clock(&item.vector_clock).is_err()
            {
                failures.push(SyncFailureSummary {
                    asset_id: None,
                    reason: "无资产 UUID 的云端记录元数据不合法".into(),
                });
                continue;
            }
            match classify_auxiliary_record(&item, master_password, account_scope) {
                Ok(true) => auxiliary_records += 1,
                Ok(false) => failures.push(SyncFailureSummary {
                    asset_id: None,
                    reason: "云端记录缺少合法资产 UUID".into(),
                }),
                Err(error) => failures.push(SyncFailureSummary {
                    asset_id: None,
                    reason: error.to_string(),
                }),
            }
            continue;
        };
        match newest.get(&asset_id) {
            Some(existing) if revision_key(existing) >= revision_key(&item) => {}
            _ => {
                newest.insert(asset_id, item);
            }
        }
    }

    let mut remote_active = 0;
    let mut conflicts = Vec::new();
    let mut tombstone_conflicts = Vec::new();
    let mut candidates = Vec::new();
    let mut satisfied = Vec::new();
    let mut deferred = Vec::new();
    for (asset_id, item) in newest {
        let state = item.state.as_deref().unwrap_or("active");
        if item.id == 0
            || item.server_revision.is_none()
            || !matches!(state, "active" | "deleted" | "purged")
            || validate_vector_clock(&item.vector_clock).is_err()
        {
            failures.push(SyncFailureSummary {
                asset_id: Some(asset_id),
                reason: "云端记录的修订、状态或向量时钟不合法".into(),
            });
            continue;
        }
        if matches!(state, "deleted" | "purged") {
            tombstones += 1;
        } else {
            remote_active += 1;
        }
        if deferred_assets.contains(&asset_id) {
            deferred.push(asset_id);
            continue;
        }
        if matches!(state, "deleted" | "purged") {
            if let Some(local) = local_by_id.get(&asset_id) {
                let restorable = state == "deleted";
                tombstone_conflicts.push(TombstoneConflict {
                    asset_id,
                    local: (*local).clone(),
                    remote: item,
                    restore_operation_id: Uuid::new_v4(),
                    restorable,
                    reason: if restorable {
                        "云端已删除，但本机仍保留此资产；需明确选择恢复或删除".into()
                    } else {
                        "云端已永久删除，但本机仍保留此资产；只能明确接受删除".into()
                    },
                });
            } else {
                satisfied.push(item);
            }
            continue;
        }
        if let Some(local) = local_by_id.get(&asset_id) {
            let revision = item.server_revision.unwrap_or(0);
            if applied_revisions
                .get(&asset_id)
                .is_some_and(|applied| *applied >= revision)
            {
                continue;
            }
            match decrypt_candidate(item, master_password, account_scope) {
                Ok(candidate) if candidate.asset.id == asset_id => {
                    conflicts.push(SyncConflict {
                        asset_id,
                        local: (*local).clone(),
                        remote: candidate,
                        reason: "本机与云端使用同一 UUID；请选择最终版本".into(),
                    });
                }
                Ok(_) => failures.push(SyncFailureSummary {
                    asset_id: Some(asset_id),
                    reason: "密文内资产 UUID 与同步记录不一致".into(),
                }),
                Err(error) => failures.push(SyncFailureSummary {
                    asset_id: Some(asset_id),
                    reason: error.to_string(),
                }),
            }
            continue;
        }
        match decrypt_candidate(item, master_password, account_scope) {
            Ok(candidate) if candidate.asset.id == asset_id => {
                candidates.push(candidate);
            }
            Ok(_) => failures.push(SyncFailureSummary {
                asset_id: Some(asset_id),
                reason: "密文内资产 UUID 与同步记录不一致".into(),
            }),
            Err(error) => failures.push(SyncFailureSummary {
                asset_id: Some(asset_id),
                reason: error.to_string(),
            }),
        }
    }
    candidates.sort_by_cached_key(|item| {
        (
            item.asset.group.to_lowercase(),
            item.asset.name.to_lowercase(),
            item.asset.id,
        )
    });
    deferred.sort_unstable();
    Ok(SyncPreview {
        candidates,
        satisfied,
        remote_active,
        auxiliary_records,
        conflicts,
        tombstones,
        tombstone_conflicts,
        deferred,
        failures,
    })
}

fn classify_auxiliary_record(
    item: &RemoteConfig,
    master_password: &str,
    account_scope: Option<&str>,
) -> Result<bool, SyncError> {
    let mut plaintext = decrypt_remote_plaintext(item, master_password, account_scope)?;
    let result = (|| {
        let value: serde_json::Value = serde_json::from_slice(&plaintext)?;
        let Some(object) = value.as_object() else {
            return Ok(false);
        };
        let Some(kind) = object.get("kind").and_then(serde_json::Value::as_str) else {
            return Ok(false);
        };
        let collection = match kind {
            "orbit_snippets" => "snippets",
            "orbit_ssh_keys" => "keys",
            "orbit_port_forwards" => "profiles",
            _ => return Ok(false),
        };
        let valid_version = object.get("version").and_then(serde_json::Value::as_u64) == Some(1);
        let valid_timestamp = object
            .get("updatedAtUnix")
            .and_then(serde_json::Value::as_i64)
            .is_some_and(|value| value > 0);
        let valid_collection = object
            .get(collection)
            .and_then(serde_json::Value::as_array)
            .is_some_and(|items| items.len() <= MAX_REMOTE_ITEMS);
        let valid_tombstones = kind == "orbit_snippets"
            || object
                .get("tombstones")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|items| items.len() <= MAX_REMOTE_ITEMS);
        if !valid_version || !valid_timestamp || !valid_collection || !valid_tombstones {
            return Err(SyncError::InvalidAuxiliaryRecord);
        }
        Ok(true)
    })();
    plaintext.zeroize();
    result
}

fn revision_key(item: &RemoteConfig) -> (u64, u64) {
    (item.server_revision.unwrap_or(0), item.id)
}

fn decrypt_candidate(
    item: RemoteConfig,
    master_password: &str,
    account_scope: Option<&str>,
) -> Result<ImportCandidate, SyncError> {
    let mut plaintext = decrypt_remote_plaintext(&item, master_password, account_scope)?;
    let decoded = serde_json::from_slice::<PortableServerConfig>(&plaintext);
    plaintext.zeroize();
    let mut portable = decoded?;
    let result =
        portable_to_candidate(&portable).map(|(asset, credential, jump_host_credential)| {
            ImportCandidate {
                asset,
                credential,
                jump_host_credential,
                remote: item,
            }
        });
    portable.password.zeroize();
    portable.private_key_content.zeroize();
    portable.private_key_passphrase.zeroize();
    if let Some(jump) = portable.jump_host.as_mut() {
        jump.password.zeroize();
        jump.private_key_content.zeroize();
        jump.private_key_passphrase.zeroize();
    }
    result
}

fn decrypt_remote_plaintext(
    item: &RemoteConfig,
    master_password: &str,
    account_scope: Option<&str>,
) -> Result<Vec<u8>, SyncError> {
    if item.encrypted_blob_base64.len() > 4 * 1024 * 1024 {
        return Err(SyncError::EncryptedBlobTooLarge);
    }
    let encrypted = BASE64.decode(item.encrypted_blob_base64.as_bytes())?;
    if orbit_core::is_config_v2(&encrypted) {
        let scope = account_scope.ok_or(SyncError::AccountScopeUnavailable)?;
        let mut root =
            orbit_core::derive_config_root_key_v2(master_password.as_bytes(), scope.as_bytes())
                .map_err(|_| SyncError::DecryptFailed)?;
        let result =
            orbit_core::decrypt_config_v2(&root, &encrypted).map_err(|_| SyncError::DecryptFailed);
        root.zeroize();
        result
    } else {
        orbit_core::decrypt_config(master_password.to_owned(), encrypted)
            .map_err(|_| SyncError::DecryptFailed)
    }
}

fn portable_to_candidate(
    portable: &PortableServerConfig,
) -> Result<LocalImportCandidate, SyncError> {
    let id = Uuid::parse_str(&portable.id).map_err(|_| SyncError::InvalidPortable)?;
    let credential_id = if portable.credential_id.is_empty() {
        id
    } else {
        Uuid::parse_str(&portable.credential_id).map_err(|_| SyncError::InvalidPortable)?
    };
    let auth_method = match portable.auth_method.as_str() {
        "password" => AuthMethod::Password,
        "key" => AuthMethod::Key,
        _ => return Err(SyncError::InvalidPortable),
    };
    let transport = match portable.transport.as_str() {
        "ssh" => Transport::Ssh,
        "telnet" => Transport::Telnet,
        "rdp" => Transport::Rdp,
        _ => return Err(SyncError::InvalidPortable),
    };
    if transport != Transport::Ssh && auth_method != AuthMethod::Password {
        return Err(SyncError::InvalidPortable);
    }
    if transport != Transport::Ssh
        && (!portable.private_key_content.is_empty()
            || !portable.private_key_passphrase.is_empty()
            || !portable.key_reference.is_empty())
    {
        return Err(SyncError::InvalidPortable);
    }
    let key_reference = if transport != Transport::Ssh || portable.private_key_content.is_empty() {
        String::new()
    } else {
        "synced-key".into()
    };
    let (jump_host, jump_host_credential) = match &portable.jump_host {
        Some(jump) if transport == Transport::Ssh => {
            let jump_credential_id =
                Uuid::parse_str(&jump.credential_id).map_err(|_| SyncError::InvalidPortable)?;
            if jump_credential_id == credential_id {
                return Err(SyncError::InvalidPortable);
            }
            let auth_method = match jump.auth_method.as_str() {
                "password" => AuthMethod::Password,
                "key" => AuthMethod::Key,
                _ => return Err(SyncError::InvalidPortable),
            };
            let configuration = JumpHostConfiguration {
                credential_id: jump_credential_id,
                host: jump.host.clone(),
                port: jump.port,
                username: jump.username.clone(),
                auth_method,
                allow_password_fallback: jump.allow_password_fallback,
                key_reference: if jump.private_key_content.is_empty() {
                    String::new()
                } else {
                    "synced-key".into()
                },
            };
            let material = CredentialMaterial {
                password: jump.password.clone(),
                private_key: jump.private_key_content.clone(),
                private_key_passphrase: jump.private_key_passphrase.clone(),
            };
            material
                .validate()
                .map_err(|_| SyncError::InvalidPortable)?;
            (Some(configuration), Some((jump_credential_id, material)))
        }
        Some(_) => return Err(SyncError::InvalidPortable),
        None => (None, None),
    };
    let asset = ServerAsset {
        id,
        credential_id,
        name: portable.name.clone(),
        group: portable.group.clone(),
        host: portable.host.clone(),
        port: portable.port,
        username: portable.username.clone(),
        auth_method,
        transport,
        allow_password_fallback: portable.allow_password_fallback,
        key_reference,
        tags: portable.tags.clone(),
        jump_host,
    };
    asset.validate().map_err(|_| SyncError::InvalidPortable)?;
    let credential = CredentialMaterial {
        password: portable.password.clone(),
        private_key: portable.private_key_content.clone(),
        private_key_passphrase: portable.private_key_passphrase.clone(),
    };
    credential
        .validate()
        .map_err(|_| SyncError::InvalidPortable)?;
    Ok((asset, credential, jump_host_credential))
}

fn portable_from_local(
    asset: &ServerAsset,
    credential: &CredentialMaterial,
    jump_host_credential: Option<&CredentialMaterial>,
) -> Result<PortableServerConfig, SyncError> {
    asset.validate().map_err(|_| SyncError::InvalidPortable)?;
    credential
        .validate()
        .map_err(|_| SyncError::InvalidPortable)?;
    let saved_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| SyncError::SystemClockInvalid)?
        .as_secs();
    Ok(PortableServerConfig {
        id: asset.id.to_string(),
        credential_id: asset.credential_id.to_string(),
        name: asset.name.clone(),
        group: asset.group.clone(),
        tags: asset.tags.clone(),
        host: asset.host.clone(),
        port: asset.port,
        username: asset.username.clone(),
        auth_method: match asset.auth_method {
            AuthMethod::Password => "password",
            AuthMethod::Key => "key",
        }
        .into(),
        transport: match asset.transport {
            Transport::Ssh => "ssh",
            Transport::Telnet => "telnet",
            Transport::Rdp => "rdp",
        }
        .into(),
        network_device_profile: "auto".into(),
        allow_password_fallback: asset.allow_password_fallback,
        password: credential.password.clone(),
        private_key_content: credential.private_key.clone(),
        private_key_passphrase: credential.private_key_passphrase.clone(),
        key_reference: asset.key_reference.clone(),
        saved_at_unix,
        jump_host: match (&asset.jump_host, jump_host_credential) {
            (Some(jump), Some(material)) => {
                material
                    .validate()
                    .map_err(|_| SyncError::InvalidPortable)?;
                Some(PortableJumpHostConfiguration {
                    credential_id: jump.credential_id.to_string(),
                    host: jump.host.clone(),
                    port: jump.port,
                    username: jump.username.clone(),
                    auth_method: match jump.auth_method {
                        AuthMethod::Password => "password",
                        AuthMethod::Key => "key",
                    }
                    .into(),
                    allow_password_fallback: jump.allow_password_fallback,
                    password: material.password.clone(),
                    private_key_content: material.private_key.clone(),
                    private_key_passphrase: material.private_key_passphrase.clone(),
                })
            }
            (None, None) => None,
            _ => return Err(SyncError::InvalidPortable),
        },
    })
}

fn remote_asset_id(remote: &RemoteConfig) -> Result<Uuid, SyncError> {
    remote
        .asset_id
        .as_deref()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(SyncError::InvalidMutationResponse)
}

fn validate_remote_asset(remote: &RemoteConfig, expected: Uuid) -> Result<(), SyncError> {
    if remote.id == 0
        || remote_asset_id(remote)? != expected
        || remote.vector_clock.len() > 64 * 1024
        || remote.vector_clock.contains('\0')
        || remote.server_revision.is_none()
    {
        return Err(SyncError::InvalidMutationResponse);
    }
    validate_vector_clock(&remote.vector_clock).map_err(|_| SyncError::InvalidMutationResponse)
}

fn validate_vector_clock(raw: &str) -> Result<(), SyncError> {
    let clock = serde_json::from_str::<HashMap<String, i64>>(raw)
        .map_err(|_| SyncError::InvalidVectorClock)?;
    if clock.len() > 128 || clock.values().any(|value| *value < 0) {
        return Err(SyncError::InvalidVectorClock);
    }
    Ok(())
}

fn validate_account_scope(scope: &str) -> Result<(), SyncError> {
    if scope.len() != 64 || !scope.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(SyncError::AccountScopeUnavailable);
    }
    Ok(())
}

fn bump_vector_clock(raw: &str, device_id: Uuid) -> Result<String, SyncError> {
    let mut clock = serde_json::from_str::<BTreeMap<String, i64>>(raw)
        .map_err(|_| SyncError::InvalidVectorClock)?;
    if clock.len() > 128 || clock.values().any(|value| *value < 0) {
        return Err(SyncError::InvalidVectorClock);
    }
    let key = device_id.to_string().to_lowercase();
    let wall_clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| SyncError::SystemClockInvalid)?
        .as_millis()
        .try_into()
        .map_err(|_| SyncError::SystemClockInvalid)?;
    let next = clock
        .get(&key)
        .copied()
        .unwrap_or(0)
        .saturating_add(1)
        .max(wall_clock);
    clock.insert(key, next);
    serde_json::to_string(&clock).map_err(SyncError::from)
}

#[derive(Debug, Error)]
pub enum SyncError {
    #[error("登录信息不合法")]
    InvalidLogin,
    #[error("主密码不能为空或超过长度限制")]
    InvalidMasterPassword,
    #[error("同步令牌不合法")]
    InvalidToken,
    #[error("登录已过期，请重新登录")]
    Unauthorized,
    #[error("登录令牌不含可验证的账户身份")]
    AccountIdentityUnavailable,
    #[error("账户加密作用域不可用，请重新登录")]
    AccountScopeUnavailable,
    #[error("服务端暂不支持增量同步端点")]
    IncrementalUnavailable,
    #[error("同步游标连续失效")]
    RepeatedCursorReset,
    #[error("服务端分页游标未前进")]
    CursorDidNotAdvance,
    #[error("服务端确认的修订号与请求值不一致")]
    InvalidAcknowledgement,
    #[error("本地同步状态不可用：{0}")]
    LocalState(String),
    #[error("云端响应结构不合法")]
    InvalidEnvelope,
    #[error("云端返回内容超过安全限制")]
    ResponseTooLarge,
    #[error("云端资产数量超过安全限制")]
    InventoryTooLarge,
    #[error("加密配置超过安全限制")]
    EncryptedBlobTooLarge,
    #[error("主密码无法解密云端资产")]
    DecryptFailed,
    #[error("无法加密本地配置")]
    EncryptFailed,
    #[error("同步向量时钟不合法")]
    InvalidVectorClock,
    #[error("系统时钟不合法")]
    SystemClockInvalid,
    #[error("服务端变更响应不合法")]
    InvalidMutationResponse,
    #[error("云端配置不符合 portable 协议")]
    InvalidPortable,
    #[error("跨端辅助同步记录不符合已知协议")]
    InvalidAuxiliaryRecord,
    #[error("服务端拒绝请求：{0}")]
    Server(String),
    #[error("同步服务暂时不可用（HTTP {0}）")]
    ServerRetryable(u16),
    #[error("同步网络请求失败：{0}")]
    Network(#[from] reqwest::Error),
    #[error("同步响应 JSON 无法解析：{0}")]
    Json(#[from] serde_json::Error),
    #[error("同步响应读取失败：{0}")]
    Io(#[from] std::io::Error),
    #[error("同步密文 Base64 无法解析：{0}")]
    Base64(#[from] base64::DecodeError),
}

impl SyncError {
    pub fn is_queueable(&self) -> bool {
        match self {
            Self::Unauthorized | Self::ServerRetryable(_) => true,
            Self::Network(error) => error.is_timeout() || error.is_connect() || error.is_request(),
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};

    fn read_http_request(stream: &mut TcpStream) -> Vec<u8> {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut chunk = [0_u8; 4096];
        loop {
            let count = stream.read(&mut chunk).unwrap();
            assert!(
                count > 0,
                "client closed before completing the HTTP request"
            );
            bytes.extend_from_slice(&chunk[..count]);
            let Some(header_end) = bytes.windows(4).position(|value| value == b"\r\n\r\n") else {
                continue;
            };
            let header_length = header_end + 4;
            let headers = String::from_utf8_lossy(&bytes[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    line.strip_prefix("content-length: ")
                        .or_else(|| line.strip_prefix("Content-Length: "))
                })
                .and_then(|value| value.trim().parse::<usize>().ok())
                .unwrap_or(0);
            if bytes.len() >= header_length + content_length {
                return bytes;
            }
        }
    }

    fn http_body(request: &[u8]) -> &[u8] {
        let start = request
            .windows(4)
            .position(|value| value == b"\r\n\r\n")
            .expect("HTTP header terminator")
            + 4;
        &request[start..]
    }

    fn remote_from_portable(portable: &PortableServerConfig, password: &str) -> RemoteConfig {
        let plaintext = serde_json::to_vec(portable).unwrap();
        let encrypted = orbit_core::encrypt_config(password.into(), plaintext).unwrap();
        RemoteConfig {
            id: 7,
            asset_id: Some(portable.id.clone()),
            encrypted_blob_base64: BASE64.encode(encrypted),
            vector_clock: r#"{"apple":1}"#.into(),
            identity_fingerprint: Some("fingerprint-fixture".into()),
            state: Some("active".into()),
            server_revision: Some(4),
            updated_at: "2026-08-23T00:00:00Z".into(),
        }
    }

    fn remote_v2_from_portable(
        portable: &PortableServerConfig,
        password: &str,
        account_scope: &str,
    ) -> RemoteConfig {
        let plaintext = serde_json::to_vec(portable).unwrap();
        let mut root =
            orbit_core::derive_config_root_key_v2(password.as_bytes(), account_scope.as_bytes())
                .unwrap();
        let encrypted = orbit_core::encrypt_config_v2(&root, &plaintext).unwrap();
        root.zeroize();
        RemoteConfig {
            id: 8,
            asset_id: Some(portable.id.clone()),
            encrypted_blob_base64: BASE64.encode(encrypted),
            vector_clock: r#"{"apple":2}"#.into(),
            identity_fingerprint: Some("fingerprint-v2-fixture".into()),
            state: Some("active".into()),
            server_revision: Some(5),
            updated_at: "2026-08-25T00:00:00Z".into(),
        }
    }

    fn portable() -> PortableServerConfig {
        PortableServerConfig {
            id: Uuid::new_v4().to_string(),
            credential_id: Uuid::new_v4().to_string(),
            name: "生产跳板机".into(),
            group: "生产".into(),
            tags: vec!["华东".into()],
            host: "10.0.0.8".into(),
            port: 22,
            username: "ops".into(),
            auth_method: "key".into(),
            transport: "ssh".into(),
            network_device_profile: "auto".into(),
            allow_password_fallback: false,
            password: String::new(),
            private_key_content: "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture\n".into(),
            private_key_passphrase: "secret".into(),
            key_reference: "/Users/apple/.ssh/id_ed25519".into(),
            saved_at_unix: 1_700_000_000,
            jump_host: None,
        }
    }

    #[test]
    fn decrypts_apple_compatible_portable_into_split_storage() {
        let portable = portable();
        let preview = build_pull_preview(
            vec![remote_from_portable(&portable, "master")],
            &[],
            &HashMap::new(),
            "master",
        )
        .unwrap();
        assert_eq!(preview.candidates.len(), 1);
        assert_eq!(preview.candidates[0].asset.id.to_string(), portable.id);
        assert_eq!(preview.candidates[0].asset.key_reference, "synced-key");
        assert!(preview.candidates[0]
            .credential
            .private_key
            .contains("PRIVATE KEY"));
    }

    #[test]
    fn preserves_telnet_and_rdp_portables_without_reinterpreting_them_as_ssh() {
        for (transport, expected, port) in [
            ("telnet", Transport::Telnet, 23),
            ("rdp", Transport::Rdp, 3389),
        ] {
            let mut portable = portable();
            portable.transport = transport.into();
            portable.port = port;
            portable.auth_method = "password".into();
            portable.password = "fixture-password".into();
            portable.private_key_content.clear();
            portable.private_key_passphrase.clear();
            portable.key_reference.clear();

            let (asset, credential, jump_credential) = portable_to_candidate(&portable).unwrap();
            assert!(jump_credential.is_none());
            assert_eq!(asset.transport, expected);
            assert_eq!(asset.port, port);
            assert_eq!(asset.auth_method, AuthMethod::Password);
            assert_eq!(credential.password, "fixture-password");

            let encoded = portable_from_local(&asset, &credential, None).unwrap();
            assert_eq!(encoded.transport, transport);
            assert!(encoded.private_key_content.is_empty());
        }
    }

    #[test]
    fn non_ssh_portable_cannot_smuggle_private_key_material() {
        let mut portable = portable();
        portable.transport = "rdp".into();
        portable.port = 3389;
        portable.auth_method = "password".into();
        portable.password = "fixture-password".into();
        assert!(matches!(
            portable_to_candidate(&portable),
            Err(SyncError::InvalidPortable)
        ));
    }

    #[test]
    fn decrypts_account_scoped_apple_v2_and_preserves_v2_on_keep_local() {
        let portable = portable();
        let scope = account_storage_identifier(" Test.User@Example.COM ").unwrap();
        let remote = remote_v2_from_portable(&portable, "master", &scope);
        let preview = build_pull_preview_for_account(
            vec![remote.clone()],
            &[],
            &HashMap::new(),
            "master",
            &scope,
        )
        .unwrap();
        assert_eq!(preview.candidates.len(), 1);
        assert!(preview.failures.is_empty());

        let candidate = &preview.candidates[0];
        let payload = CloudClient::for_endpoint("http://127.0.0.1:9")
            .unwrap()
            .prepare_keep_local_for_account(
                &candidate.asset,
                &candidate.credential,
                candidate
                    .jump_host_credential
                    .as_ref()
                    .map(|(_, credential)| credential),
                KeepLocalAccountContext {
                    remote: &remote,
                    master_password: "master",
                    device_id: Uuid::new_v4(),
                    account_scope: &scope,
                },
            )
            .unwrap();
        let QueuedSyncPayload::Upload {
            encrypted_blob_base64,
            ..
        } = payload
        else {
            panic!("keep-local must prepare an upload");
        };
        let encoded = BASE64.decode(encrypted_blob_base64).unwrap();
        assert!(orbit_core::is_config_v2(&encoded));
    }

    #[test]
    fn recognizes_known_account_scoped_auxiliary_records_without_blocking_assets() {
        let scope = account_storage_identifier("test.user@example.com").unwrap();
        let plaintext = br#"{"kind":"orbit_port_forwards","version":1,"updatedAtUnix":1770000000,"profiles":[],"tombstones":[]}"#;
        let mut root = orbit_core::derive_config_root_key_v2(b"master", scope.as_bytes()).unwrap();
        let encrypted = orbit_core::encrypt_config_v2(&root, plaintext).unwrap();
        root.zeroize();
        let auxiliary = RemoteConfig {
            id: 43,
            asset_id: Some(String::new()),
            encrypted_blob_base64: BASE64.encode(encrypted),
            vector_clock: r#"{"apple":3}"#.into(),
            identity_fingerprint: None,
            state: Some("active".into()),
            server_revision: Some(737),
            updated_at: "2026-08-25T00:00:00Z".into(),
        };

        let preview =
            build_pull_preview_for_account(vec![auxiliary], &[], &HashMap::new(), "master", &scope)
                .unwrap();

        assert_eq!(preview.auxiliary_records, 1);
        assert_eq!(preview.remote_active, 0);
        assert!(preview.candidates.is_empty());
        assert!(preview.failures.is_empty());
        assert_eq!(preview.unresolved_count(), 0);
    }

    #[test]
    fn malformed_or_unknown_unbound_records_remain_fail_closed() {
        let malformed = |kind: &str, version: u64, id: u64| {
            let plaintext = serde_json::to_vec(&serde_json::json!({
                "kind": kind,
                "version": version,
                "updatedAtUnix": 1_770_000_000_u64,
                "profiles": [],
                "tombstones": []
            }))
            .unwrap();
            let encrypted = orbit_core::encrypt_config("master".into(), plaintext).unwrap();
            RemoteConfig {
                id,
                asset_id: None,
                encrypted_blob_base64: BASE64.encode(encrypted),
                vector_clock: r#"{"apple":3}"#.into(),
                identity_fingerprint: None,
                state: Some("active".into()),
                server_revision: Some(id),
                updated_at: "2026-08-25T00:00:00Z".into(),
            }
        };
        let preview = build_pull_preview(
            vec![
                malformed("orbit_port_forwards", 2, 44),
                malformed("orbit_unknown", 1, 45),
            ],
            &[],
            &HashMap::new(),
            "master",
        )
        .unwrap();

        assert_eq!(preview.auxiliary_records, 0);
        assert_eq!(preview.failures.len(), 2);
        assert_eq!(preview.unresolved_count(), 2);
    }

    #[test]
    fn never_overwrites_matching_local_asset_during_pull_preview() {
        let portable = portable();
        let local = portable_to_candidate(&portable).unwrap().0;
        let preview = build_pull_preview(
            vec![remote_from_portable(&portable, "master")],
            &[local],
            &HashMap::new(),
            "master",
        )
        .unwrap();
        assert!(preview.candidates.is_empty());
        assert_eq!(preview.conflicts.len(), 1);
        assert_eq!(preview.conflicts[0].remote.asset.name, portable.name);
    }

    #[test]
    fn already_applied_remote_revision_does_not_reopen_conflict() {
        let portable = portable();
        let local = portable_to_candidate(&portable).unwrap().0;
        let preview = build_pull_preview(
            vec![remote_from_portable(&portable, "master")],
            std::slice::from_ref(&local),
            &HashMap::from([(local.id, 4)]),
            "master",
        )
        .unwrap();
        assert!(preview.candidates.is_empty());
        assert_eq!(preview.unresolved_count(), 0);
        assert!(preview.satisfied.is_empty());
    }

    #[test]
    fn wrong_master_password_reports_failure_without_partial_candidate() {
        let portable = portable();
        let preview = build_pull_preview(
            vec![remote_from_portable(&portable, "correct")],
            &[],
            &HashMap::new(),
            "wrong",
        )
        .unwrap();
        assert!(preview.candidates.is_empty());
        assert_eq!(preview.failures.len(), 1);
    }

    #[test]
    fn malformed_remote_metadata_is_blocked_before_any_action() {
        let portable = portable();
        let mut remote = remote_from_portable(&portable, "master");
        remote.state = Some("unknown".into());
        remote.vector_clock = r#"{"apple":-1}"#.into();
        let preview = build_pull_preview(vec![remote], &[], &HashMap::new(), "master").unwrap();
        assert!(preview.candidates.is_empty());
        assert_eq!(preview.failures.len(), 1);
        assert_eq!(preview.unresolved_count(), 1);
    }

    #[test]
    fn queued_asset_stays_deferred_without_decrypting_or_advancing() {
        let portable = portable();
        let asset_id = Uuid::parse_str(&portable.id).unwrap();
        let remote = remote_from_portable(&portable, "correct-master");
        let preview = build_pull_preview_with_deferred(
            vec![remote],
            &[],
            &HashMap::new(),
            &std::collections::HashSet::from([asset_id]),
            "intentionally-wrong-master",
        )
        .unwrap();
        assert_eq!(preview.deferred, vec![asset_id]);
        assert!(preview.failures.is_empty());
        assert_eq!(preview.unresolved_count(), 1);
    }

    #[test]
    fn tombstone_only_blocks_cursor_when_asset_still_exists_locally() {
        let portable = portable();
        let local = portable_to_candidate(&portable).unwrap().0;
        let mut tombstone = remote_from_portable(&portable, "master");
        tombstone.state = Some("deleted".into());
        tombstone.encrypted_blob_base64.clear();
        let local_preview = build_pull_preview(
            vec![tombstone.clone()],
            std::slice::from_ref(&local),
            &HashMap::new(),
            "master",
        )
        .unwrap();
        assert_eq!(local_preview.tombstones, 1);
        assert_eq!(local_preview.tombstone_conflicts.len(), 1);
        assert_eq!(local_preview.unresolved_count(), 1);
        let absent_preview =
            build_pull_preview(vec![tombstone], &[], &HashMap::new(), "master").unwrap();
        assert_eq!(absent_preview.tombstones, 1);
        assert_eq!(absent_preview.unresolved_count(), 0);
    }

    #[test]
    fn purged_tombstone_is_satisfied_only_when_local_asset_is_absent() {
        let portable = portable();
        let local = portable_to_candidate(&portable).unwrap().0;
        let mut tombstone = remote_from_portable(&portable, "master");
        tombstone.state = Some("purged".into());
        tombstone.encrypted_blob_base64.clear();

        let local_preview = build_pull_preview(
            vec![tombstone.clone()],
            std::slice::from_ref(&local),
            &HashMap::new(),
            "master",
        )
        .unwrap();
        assert_eq!(local_preview.tombstones, 1);
        assert_eq!(local_preview.tombstone_conflicts.len(), 1);
        assert!(!local_preview.tombstone_conflicts[0].restorable);
        assert_eq!(local_preview.unresolved_count(), 1);

        let absent_preview =
            build_pull_preview(vec![tombstone], &[], &HashMap::new(), "master").unwrap();
        assert_eq!(absent_preview.tombstones, 1);
        assert_eq!(absent_preview.satisfied.len(), 1);
        assert!(absent_preview.failures.is_empty());
        assert_eq!(absent_preview.unresolved_count(), 0);
    }

    #[test]
    fn tokens_refuse_empty_access_token() {
        assert!(matches!(
            SyncTokens::default().validate(),
            Err(SyncError::InvalidToken)
        ));
    }

    #[test]
    fn production_client_is_https_only() {
        assert!(CloudClient::production().is_ok());
        assert!(CloudClient::for_endpoint("http://127.0.0.1:9").is_ok());
    }

    #[test]
    fn account_fingerprint_matches_for_numeric_and_string_uid() {
        let numeric = format!("x.{}.y", URL_SAFE_NO_PAD.encode(br#"{"uid":42}"#));
        let string = format!("x.{}.y", URL_SAFE_NO_PAD.encode(br#"{"uid":"42"}"#));
        assert_eq!(account_fingerprint(&numeric).unwrap().len(), 12);
        assert_eq!(
            account_fingerprint(&numeric).unwrap(),
            account_fingerprint(&string).unwrap()
        );
        assert!(matches!(
            account_fingerprint("not-a-jwt"),
            Err(SyncError::AccountIdentityUnavailable)
        ));
    }

    #[test]
    fn incremental_pull_recovers_one_reset_and_paginates() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            for step in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 8192];
                let count = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..count]);
                let body = match step {
                    0 => {
                        assert!(
                            request.starts_with("GET /api/v1/config/sync/pull?cursor=9&limit=100 ")
                        );
                        r#"{"success":true,"data":{"items":[],"next_cursor":9,"has_more":false,"reset_required":true},"error":null}"#
                    }
                    1 => {
                        assert!(
                            request.starts_with("GET /api/v1/config/sync/pull?cursor=0&limit=100 ")
                        );
                        r#"{"success":true,"data":{"items":[],"next_cursor":5,"has_more":true,"reset_required":false},"error":null}"#
                    }
                    _ => {
                        assert!(
                            request.starts_with("GET /api/v1/config/sync/pull?cursor=5&limit=100 ")
                        );
                        r#"{"success":true,"data":{"items":[],"next_cursor":7,"has_more":false,"reset_required":false},"error":null}"#
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let batch = client.pull_changes(&mut tokens, 9).unwrap();
        assert_eq!(batch.next_cursor, 7);
        assert!(batch.reset_recovered);
        assert!(batch.items.is_empty());
        server.join().unwrap();
    }

    #[test]
    fn acknowledgement_uses_linux_device_contract() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let device_id = Uuid::new_v4();
        let expected_device = device_id.to_string();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 8192];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("POST /api/v1/config/sync/ack "));
            assert!(request.contains(&format!(r#""device_id":"{expected_device}""#)));
            assert!(request.contains(r#""revision":17"#));
            assert!(request.contains(r#""platform":"linux""#));
            let body = r#"{"success":true,"data":{"acknowledged_revision":17},"error":null}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        assert_eq!(client.acknowledge(&mut tokens, device_id, 17).unwrap(), 17);
        server.join().unwrap();
    }

    #[test]
    fn keep_local_uploads_encrypted_portable_with_remote_identity_and_revision() {
        let portable = portable();
        let (asset, credential, _) = portable_to_candidate(&portable).unwrap();
        let mut remote = remote_from_portable(&portable, "master");
        remote.id = 23;
        remote.server_revision = Some(8);
        let asset_id = asset.id;
        let expected_asset = asset_id.to_string();
        let device_id = Uuid::new_v4();
        let expected_device = device_id.to_string();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let response_asset = expected_asset.clone();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 32 * 1024];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with("POST /api/v1/config/upload "));
            assert!(request.contains(r#""id":23"#));
            assert!(request.contains(r#""asset_id":null"#));
            assert!(request.contains(r#""identity_fingerprint":"fingerprint-fixture""#));
            assert!(request.contains(&expected_device));
            assert!(!request.contains("PRIVATE KEY"));
            assert!(!request.contains("prod.example"));
            let body = format!(
                r#"{{"success":true,"data":{{"id":23,"asset_id":"{response_asset}","encrypted_blob_base64":"cipher","vector_clock":"{{\"linux\":99}}","identity_fingerprint":"fingerprint-fixture","state":"active","server_revision":9,"updated_at":"2026-08-23T00:00:00Z"}},"error":null}}"#
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let response = client
            .keep_local(
                &mut tokens,
                &asset,
                &credential,
                &remote,
                "master",
                device_id,
            )
            .unwrap();
        assert_eq!(response.server_revision, Some(9));
        server.join().unwrap();
    }

    #[test]
    fn keep_local_accepts_legacy_uppercase_remote_asset_id() {
        let portable = portable();
        let (asset, credential, _) = portable_to_candidate(&portable).unwrap();
        let mut remote = remote_from_portable(&portable, "master");
        remote.id = 23;
        remote.asset_id = Some(asset.id.to_string().to_uppercase());
        remote.server_revision = Some(8);
        let response_asset = remote.asset_id.clone().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let request = read_http_request(&mut stream);
            let request = String::from_utf8_lossy(&request);
            assert!(request.starts_with("POST /api/v1/config/upload "));
            assert!(request.contains(r#""id":23"#));
            assert!(request.contains(r#""asset_id":null"#));
            let body = format!(
                r#"{{"success":true,"data":{{"id":23,"asset_id":"{response_asset}","encrypted_blob_base64":"cipher","vector_clock":"{{\"linux\":99}}","identity_fingerprint":"fingerprint-fixture","state":"active","server_revision":9,"updated_at":"2026-08-23T00:00:00Z"}},"error":null}}"#
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let response = client
            .keep_local(
                &mut tokens,
                &asset,
                &credential,
                &remote,
                "master",
                Uuid::new_v4(),
            )
            .unwrap();
        assert_eq!(response.server_revision, Some(9));
        server.join().unwrap();
    }

    #[test]
    fn restore_cloud_uses_stable_operation_and_vector_clock() {
        let portable = portable();
        let asset_id = Uuid::parse_str(&portable.id).unwrap();
        let mut remote = remote_from_portable(&portable, "master");
        remote.state = Some("deleted".into());
        let device_id = Uuid::new_v4();
        let operation_id = Uuid::new_v4();
        let expected_device = device_id.to_string();
        let expected_operation = operation_id.to_string();
        let expected_path = format!("POST /api/v1/config/assets/{asset_id}/restore ");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 16 * 1024];
            let count = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.starts_with(&expected_path));
            assert!(request.contains(&format!(r#""device_id":"{expected_device}""#)));
            assert!(request.contains(&format!(r#""operation_id":"{expected_operation}""#)));
            let body = format!(
                r#"{{"success":true,"data":{{"id":7,"asset_id":"{asset_id}","encrypted_blob_base64":"cipher","vector_clock":"{{\"linux\":99}}","identity_fingerprint":"fingerprint-fixture","state":"active","server_revision":5,"updated_at":"2026-08-23T00:00:00Z"}},"error":null}}"#
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let response = client
            .restore_asset(&mut tokens, &remote, device_id, operation_id)
            .unwrap();
        assert_eq!(response.state.as_deref(), Some("active"));
        server.join().unwrap();
    }

    #[test]
    fn restore_cloud_replays_legacy_uppercase_asset_path_idempotently() {
        let portable = portable();
        let asset_id = Uuid::parse_str(&portable.id).unwrap();
        let mut remote = remote_from_portable(&portable, "master");
        remote.asset_id = Some(asset_id.to_string().to_uppercase());
        remote.state = Some("deleted".into());
        let device_id = Uuid::new_v4();
        let operation_id = Uuid::new_v4();
        let lower_path = format!("POST /api/v1/config/assets/{asset_id}/restore ");
        let upper_path = format!(
            "POST /api/v1/config/assets/{}/restore ",
            asset_id.to_string().to_uppercase()
        );
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            let (mut first, _) = listener.accept().unwrap();
            let first_request = read_http_request(&mut first);
            assert!(String::from_utf8_lossy(&first_request).starts_with(&lower_path));
            let first_body = http_body(&first_request).to_vec();
            write!(
                first,
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();

            let (mut second, _) = listener.accept().unwrap();
            let second_request = read_http_request(&mut second);
            assert!(String::from_utf8_lossy(&second_request).starts_with(&upper_path));
            assert_eq!(first_body, http_body(&second_request));
            let response_asset = asset_id.to_string().to_uppercase();
            let body = format!(
                r#"{{"success":true,"data":{{"id":7,"asset_id":"{response_asset}","encrypted_blob_base64":"cipher","vector_clock":"{{\"linux\":99}}","identity_fingerprint":"fingerprint-fixture","state":"active","server_revision":6,"updated_at":"2026-08-23T00:00:00Z"}},"error":null}}"#
            );
            write!(
                second,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let response = client
            .restore_asset(&mut tokens, &remote, device_id, operation_id)
            .unwrap();
        assert_eq!(response.server_revision, Some(6));
        server.join().unwrap();
    }

    #[test]
    fn queued_upload_replay_sends_the_exact_same_idempotent_body() {
        let asset_id = Uuid::new_v4();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let response_asset = asset_id.to_string();
        let server = std::thread::spawn(move || {
            let mut bodies = Vec::new();
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_http_request(&mut stream);
                assert!(request.starts_with(b"POST /api/v1/config/upload "));
                bodies.push(http_body(&request).to_vec());
                let body = format!(
                    r#"{{"success":true,"data":{{"id":23,"asset_id":"{response_asset}","encrypted_blob_base64":"cipher","vector_clock":"{{\"linux\":9}}","identity_fingerprint":"fixture","state":"active","server_revision":10,"updated_at":"2026-08-23T00:00:00Z"}},"error":null}}"#
                );
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            assert_eq!(bodies[0], bodies[1]);
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let payload = QueuedSyncPayload::Upload {
            remote_id: 23,
            asset_id,
            identity_fingerprint: Some("fixture".into()),
            encrypted_blob_base64: "stable-ciphertext".into(),
            vector_clock: r#"{"linux":9}"#.into(),
        };
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let first = client.execute_queued(&mut tokens, &payload).unwrap();
        let second = client.execute_queued(&mut tokens, &payload).unwrap();
        assert_eq!(first.server_revision, second.server_revision);
        server.join().unwrap();
    }

    #[test]
    fn server_5xx_is_bounded_and_classified_for_queue_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let request = read_http_request(&mut stream);
                assert!(request.starts_with(b"GET /api/v1/config/pull "));
                write!(
                    stream,
                    "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                )
                .unwrap();
            }
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let error = client.pull_inventory(&mut tokens).unwrap_err();
        assert!(matches!(error, SyncError::ServerRetryable(503)));
        assert!(error.is_queueable());
        server.join().unwrap();
    }

    #[test]
    fn refused_connection_is_classified_for_queue_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        drop(listener);
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        let error = client.pull_inventory(&mut tokens).unwrap_err();
        assert!(matches!(error, SyncError::Network(_)));
        assert!(error.is_queueable());
    }

    #[test]
    fn production_tls_rejects_invalid_bearer_when_opted_in() {
        if std::env::var("ORBITTERM_RUN_CLOUD_READ_SMOKE").as_deref() != Ok("1") {
            return;
        }
        let client = CloudClient::production().unwrap();
        let mut tokens = SyncTokens {
            access_token: "invalid-linux-read-smoke-token".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        assert!(matches!(
            client.pull_inventory(&mut tokens),
            Err(SyncError::Unauthorized)
        ));
        assert!(matches!(
            client.pull_changes(&mut tokens, 0),
            Err(SyncError::Unauthorized)
        ));
    }

    #[test]
    fn refreshes_once_after_unauthorized_then_retries_pull() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint: &'static str =
            Box::leak(format!("http://{}", listener.local_addr().unwrap()).into_boxed_str());
        let server = std::thread::spawn(move || {
            for step in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = [0_u8; 8192];
                let count = stream.read(&mut request).unwrap();
                let request = String::from_utf8_lossy(&request[..count]);
                let (status, body) = match step {
                    0 => {
                        assert!(request.starts_with("GET /api/v1/config/pull "));
                        (
                            "401 Unauthorized",
                            r#"{"success":false,"data":null,"error":"expired"}"#,
                        )
                    }
                    1 => {
                        assert!(request.starts_with("POST /api/v1/auth/refresh "));
                        (
                            "200 OK",
                            r#"{"success":true,"data":{"access_token":"new-access","refresh_token":"new-refresh"},"error":null}"#,
                        )
                    }
                    _ => {
                        assert!(request.starts_with("GET /api/v1/config/pull "));
                        assert!(request
                            .to_ascii_lowercase()
                            .contains("authorization: bearer new-access"));
                        (
                            "200 OK",
                            r#"{"success":true,"data":{"items":[]},"error":null}"#,
                        )
                    }
                };
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
        });
        let client = CloudClient::for_endpoint(endpoint).unwrap();
        let mut tokens = SyncTokens {
            access_token: "expired-access".into(),
            refresh_token: "refresh-token".into(),
            account_scope: String::new(),
        };
        assert!(client.pull_inventory(&mut tokens).unwrap().is_empty());
        assert_eq!(tokens.access_token, "new-access");
        assert_eq!(tokens.refresh_token, "new-refresh");
        server.join().unwrap();
    }
}
