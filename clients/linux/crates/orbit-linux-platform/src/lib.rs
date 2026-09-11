use orbit_linux_application::{AssetRepository, RepositoryError};
use orbit_linux_domain::ServerAsset;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use thiserror::Error;
use uuid::Uuid;
use zeroize::Zeroize;

mod sync_operations;
pub use sync_operations::{
    current_unix_ms, QueuedSyncOperation, QueuedSyncPayload, SyncAuditEvent, SyncAuditOutcome,
    SyncOperationKind, SyncOperationRepository,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct XdgPaths {
    pub config: PathBuf,
    pub data: PathBuf,
    pub state: PathBuf,
    pub cache: PathBuf,
}

impl XdgPaths {
    pub fn discover() -> Result<Self, PlatformError> {
        let home = env::var_os("HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .ok_or(PlatformError::HomeUnavailable)?;
        Ok(Self::from_bases(
            absolute_env("XDG_CONFIG_HOME").unwrap_or_else(|| home.join(".config")),
            absolute_env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share")),
            absolute_env("XDG_STATE_HOME").unwrap_or_else(|| home.join(".local/state")),
            absolute_env("XDG_CACHE_HOME").unwrap_or_else(|| home.join(".cache")),
        ))
    }

    pub fn from_bases(config: PathBuf, data: PathBuf, state: PathBuf, cache: PathBuf) -> Self {
        Self {
            config: config.join("OrbitTerm"),
            data: data.join("OrbitTerm"),
            state: state.join("OrbitTerm"),
            cache: cache.join("OrbitTerm"),
        }
    }

    pub fn assets_file(&self) -> PathBuf {
        self.data.join("assets.json")
    }

    pub fn known_hosts_file(&self) -> PathBuf {
        self.state.join("security/known_hosts")
    }

    pub fn sync_state_file(&self) -> PathBuf {
        self.state.join("sync/state.json")
    }

    pub fn sync_operations_file(&self) -> PathBuf {
        self.state.join("sync/operations.json")
    }

    pub fn rdp_config_dir(&self) -> PathBuf {
        self.state.join("remote-desktop")
    }

    pub fn preferences_file(&self) -> PathBuf {
        self.config.join("preferences.json")
    }

    pub fn port_forward_profiles_file(&self) -> PathBuf {
        self.data.join("port-forward-profiles.json")
    }

    pub fn snippets_file(&self) -> PathBuf {
        self.data.join("snippets.json")
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SnippetScopeMode {
    AllAssets,
    SelectedAssets,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SnippetAssetScope {
    pub mode: SnippetScopeMode,
    #[serde(default)]
    pub asset_ids: Vec<Uuid>,
}

impl Default for SnippetAssetScope {
    fn default() -> Self {
        Self {
            mode: SnippetScopeMode::AllAssets,
            asset_ids: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandSnippet {
    pub id: Uuid,
    pub title: String,
    pub command: String,
    pub category: String,
    #[serde(default)]
    pub asset_scope: SnippetAssetScope,
    pub created_at_unix_ms: i64,
    pub updated_at_unix_ms: i64,
}

impl CommandSnippet {
    fn validate(&self) -> Result<(), PlatformError> {
        let valid_text = |value: &str, maximum: usize| {
            !value.trim().is_empty()
                && value.len() <= maximum
                && !value.chars().any(|character| character == '\0')
        };
        let unique_assets = self
            .asset_scope
            .asset_ids
            .iter()
            .copied()
            .collect::<std::collections::HashSet<_>>();
        if self.id.is_nil()
            || !valid_text(&self.title, 128)
            || !valid_text(&self.command, 65_536)
            || self.category.len() > 128
            || self.category.chars().any(char::is_control)
            || self.created_at_unix_ms <= 0
            || self.updated_at_unix_ms < self.created_at_unix_ms
            || unique_assets.len() != self.asset_scope.asset_ids.len()
            || self.asset_scope.asset_ids.iter().any(Uuid::is_nil)
            || matches!(self.asset_scope.mode, SnippetScopeMode::AllAssets)
                && !self.asset_scope.asset_ids.is_empty()
            || matches!(self.asset_scope.mode, SnippetScopeMode::SelectedAssets)
                && self.asset_scope.asset_ids.is_empty()
        {
            Err(PlatformError::InvalidSnippets)
        } else {
            Ok(())
        }
    }

    pub fn applies_to(&self, asset_id: Uuid) -> bool {
        matches!(self.asset_scope.mode, SnippetScopeMode::AllAssets)
            || self.asset_scope.asset_ids.contains(&asset_id)
    }
}

#[derive(Clone, Debug)]
pub struct SnippetRepository {
    path: PathBuf,
}

impl SnippetRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> Result<Vec<CommandSnippet>, PlatformError> {
        let mut snippets = match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice::<Vec<CommandSnippet>>(&bytes)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error.into()),
        };
        let unique = snippets
            .iter()
            .map(|snippet| snippet.id)
            .collect::<std::collections::HashSet<_>>();
        if snippets.len() > 2_000
            || unique.len() != snippets.len()
            || snippets.iter().any(|snippet| snippet.validate().is_err())
        {
            return Err(PlatformError::InvalidSnippets);
        }
        snippets.sort_by_cached_key(|snippet| {
            (
                snippet.category.to_lowercase(),
                snippet.title.to_lowercase(),
                snippet.id,
            )
        });
        Ok(snippets)
    }

    pub fn upsert(&self, snippet: CommandSnippet) -> Result<(), PlatformError> {
        snippet.validate()?;
        let mut snippets = self.load()?;
        if let Some(existing) = snippets.iter_mut().find(|item| item.id == snippet.id) {
            *existing = snippet;
        } else {
            if snippets.len() >= 2_000 {
                return Err(PlatformError::InvalidSnippets);
            }
            snippets.push(snippet);
        }
        snippets.sort_by_cached_key(|item| {
            (
                item.category.to_lowercase(),
                item.title.to_lowercase(),
                item.id,
            )
        });
        secure_atomic_json_write(&self.path, &snippets)
    }

    pub fn remove(&self, id: Uuid) -> Result<(), PlatformError> {
        let mut snippets = self.load()?;
        snippets.retain(|snippet| snippet.id != id);
        secure_atomic_json_write(&self.path, &snippets)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PortForwardProfile {
    pub id: Uuid,
    pub asset_id: Uuid,
    pub name: String,
    pub bind_host: String,
    pub bind_port: u16,
    pub destination_host: String,
    pub destination_port: u16,
    pub end_to_end_sync: bool,
}

impl PortForwardProfile {
    fn validate(&self) -> Result<(), PlatformError> {
        if self.id.is_nil()
            || self.asset_id.is_nil()
            || self.name.trim().is_empty()
            || self.name.len() > 128
            || self.name.chars().any(char::is_control)
            || !matches!(self.bind_host.as_str(), "127.0.0.1" | "::1")
            || self.destination_host.trim().is_empty()
            || self.destination_host.len() > 253
            || self
                .destination_host
                .chars()
                .any(|character| character.is_control() || character.is_whitespace())
            || self.destination_port == 0
        {
            Err(PlatformError::InvalidPortForwardProfiles)
        } else {
            Ok(())
        }
    }
}

#[derive(Clone, Debug)]
pub struct PortForwardProfileRepository {
    path: PathBuf,
}

impl PortForwardProfileRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> Result<Vec<PortForwardProfile>, PlatformError> {
        let profiles = match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice::<Vec<PortForwardProfile>>(&bytes)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
            Err(error) => return Err(error.into()),
        };
        if profiles.len() > 2_000
            || profiles.iter().any(|profile| profile.validate().is_err())
            || profiles
                .iter()
                .map(|profile| profile.id)
                .collect::<std::collections::HashSet<_>>()
                .len()
                != profiles.len()
        {
            return Err(PlatformError::InvalidPortForwardProfiles);
        }
        Ok(profiles)
    }

    pub fn upsert(&self, profile: PortForwardProfile) -> Result<(), PlatformError> {
        profile.validate()?;
        let mut profiles = self.load()?;
        if let Some(existing) = profiles.iter_mut().find(|item| item.id == profile.id) {
            *existing = profile;
        } else {
            if profiles.len() >= 2_000 {
                return Err(PlatformError::InvalidPortForwardProfiles);
            }
            profiles.push(profile);
        }
        profiles.sort_by_cached_key(|item| (item.asset_id, item.name.to_lowercase(), item.id));
        secure_atomic_json_write(&self.path, &profiles)
    }

    pub fn remove(&self, id: Uuid) -> Result<(), PlatformError> {
        let mut profiles = self.load()?;
        profiles.retain(|profile| profile.id != id);
        secure_atomic_json_write(&self.path, &profiles)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppPreferences {
    pub terminal_font_size: i32,
    pub terminal_scrollback_lines: i64,
    pub cursor_blink: bool,
    pub application_theme: String,
    #[serde(default = "default_application_palette")]
    pub application_palette: String,
    pub terminal_theme: String,
    pub terminal_follows_application_theme: bool,
    pub monitor_auto_refresh: bool,
    pub monitor_refresh_seconds: u64,
    pub monitor_history_samples: usize,
    pub telnet_enabled: bool,
    pub synchronize_key_library: bool,
}

impl Default for AppPreferences {
    fn default() -> Self {
        Self {
            terminal_font_size: 13,
            terminal_scrollback_lines: 50_000,
            cursor_blink: true,
            application_theme: "system".into(),
            application_palette: default_application_palette(),
            terminal_theme: "dracula".into(),
            terminal_follows_application_theme: false,
            monitor_auto_refresh: true,
            monitor_refresh_seconds: 2,
            monitor_history_samples: 300,
            telnet_enabled: false,
            synchronize_key_library: false,
        }
    }
}

impl AppPreferences {
    fn validate(&self) -> Result<(), PlatformError> {
        if !(8..=24).contains(&self.terminal_font_size)
            || !(1_000..=200_000).contains(&self.terminal_scrollback_lines)
            || !matches!(self.application_theme.as_str(), "system" | "light" | "dark")
            || !matches!(
                self.application_palette.as_str(),
                "sky" | "emerald" | "peach" | "lavender" | "glacier"
            )
            || !matches!(
                self.terminal_theme.as_str(),
                "dracula" | "solarized-dark" | "nord" | "homebrew"
            )
            || !matches!(self.monitor_refresh_seconds, 1 | 2 | 5)
            || !matches!(self.monitor_history_samples, 120 | 300 | 600)
        {
            Err(PlatformError::InvalidPreferences)
        } else {
            Ok(())
        }
    }
}

fn default_application_palette() -> String {
    "emerald".into()
}

#[derive(Clone, Debug)]
pub struct PreferencesRepository {
    path: PathBuf,
}

impl PreferencesRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn load(&self) -> Result<AppPreferences, PlatformError> {
        let preferences = match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => AppPreferences::default(),
            Err(error) => return Err(error.into()),
        };
        preferences.validate()?;
        Ok(preferences)
    }

    pub fn save(&self, preferences: &AppPreferences) -> Result<(), PlatformError> {
        preferences.validate()?;
        secure_atomic_json_write(&self.path, preferences)
    }
}

fn absolute_env(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
}

#[derive(Clone, Debug)]
pub struct JsonAssetRepository {
    path: PathBuf,
}

impl JsonAssetRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

impl AssetRepository for JsonAssetRepository {
    fn load(&self) -> Result<Vec<ServerAsset>, RepositoryError> {
        match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| RepositoryError::Invalid(error.to_string())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(error) => Err(RepositoryError::Unavailable(error.to_string())),
        }
    }

    fn save(&self, assets: &[ServerAsset]) -> Result<(), RepositoryError> {
        secure_atomic_json_write(&self.path, assets)
            .map_err(|error| RepositoryError::Unavailable(error.to_string()))
    }
}

#[derive(Clone, Debug)]
pub struct SyncStateRepository {
    path: PathBuf,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct SyncStateDocument {
    version: u8,
    device_id: Uuid,
    accounts: HashMap<String, AccountSyncState>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AccountSyncState {
    cursor: u64,
    #[serde(default)]
    assets: HashMap<Uuid, AssetSyncState>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetSyncState {
    pub remote_id: u64,
    pub vector_clock: String,
    pub state: String,
    pub server_revision: u64,
    pub applied: bool,
    #[serde(default)]
    pub local_fingerprint: Option<String>,
}

impl SyncStateRepository {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn device_id(&self) -> Result<Uuid, PlatformError> {
        Ok(self.load_or_create()?.device_id)
    }

    pub fn cursor(&self, account_fingerprint: &str) -> Result<u64, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        Ok(self
            .load_or_create()?
            .accounts
            .get(account_fingerprint)
            .map_or(0, |state| state.cursor))
    }

    pub fn save_cursor(&self, account_fingerprint: &str, cursor: u64) -> Result<(), PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let mut document = self.load_or_create()?;
        if !document.accounts.contains_key(account_fingerprint) && document.accounts.len() >= 32 {
            return Err(PlatformError::TooManySyncAccounts);
        }
        document
            .accounts
            .entry(account_fingerprint.to_owned())
            .or_default()
            .cursor = cursor;
        secure_atomic_json_write(&self.path, &document)
    }

    pub fn asset(
        &self,
        account_fingerprint: &str,
        asset_id: Uuid,
    ) -> Result<Option<AssetSyncState>, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        Ok(self
            .load_or_create()?
            .accounts
            .get(account_fingerprint)
            .and_then(|state| state.assets.get(&asset_id))
            .cloned())
    }

    pub fn applied_revisions(
        &self,
        account_fingerprint: &str,
        local_assets: &[ServerAsset],
    ) -> Result<HashMap<Uuid, u64>, PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        let metadata = self
            .load_or_create()?
            .accounts
            .get(account_fingerprint)
            .map(|state| state.assets.clone())
            .unwrap_or_default();
        let mut revisions = HashMap::new();
        for asset in local_assets {
            let Some(state) = metadata.get(&asset.id) else {
                continue;
            };
            let local_fingerprint = asset_sync_fingerprint(asset)?;
            if state.applied
                && state.local_fingerprint.as_deref() == Some(local_fingerprint.as_str())
            {
                revisions.insert(asset.id, state.server_revision);
            }
        }
        Ok(revisions)
    }

    pub fn save_asset(
        &self,
        account_fingerprint: &str,
        asset_id: Uuid,
        metadata: AssetSyncState,
    ) -> Result<(), PlatformError> {
        validate_account_fingerprint(account_fingerprint)?;
        validate_asset_sync_state(&metadata)?;
        let mut document = self.load_or_create()?;
        if !document.accounts.contains_key(account_fingerprint) && document.accounts.len() >= 32 {
            return Err(PlatformError::TooManySyncAccounts);
        }
        let account = document
            .accounts
            .entry(account_fingerprint.to_owned())
            .or_default();
        if !account.assets.contains_key(&asset_id) && account.assets.len() >= 10_000 {
            return Err(PlatformError::TooManySyncAssets);
        }
        let should_replace = match account.assets.get(&asset_id) {
            Some(existing) if existing.server_revision > metadata.server_revision => false,
            Some(existing)
                if existing.server_revision == metadata.server_revision
                    && existing.applied
                    && !metadata.applied =>
            {
                false
            }
            _ => true,
        };
        if should_replace {
            account.assets.insert(asset_id, metadata);
            secure_atomic_json_write(&self.path, &document)?;
        }
        Ok(())
    }

    fn load_or_create(&self) -> Result<SyncStateDocument, PlatformError> {
        let document = match fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice::<SyncStateDocument>(&bytes)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let document = SyncStateDocument {
                    version: 1,
                    device_id: Uuid::new_v4(),
                    accounts: HashMap::new(),
                };
                secure_atomic_json_write(&self.path, &document)?;
                document
            }
            Err(error) => return Err(error.into()),
        };
        if document.version != 1
            || document.device_id.is_nil()
            || document.accounts.len() > 32
            || document
                .accounts
                .keys()
                .any(|fingerprint| validate_account_fingerprint(fingerprint).is_err())
            || document.accounts.values().any(|account| {
                account.assets.len() > 10_000
                    || account
                        .assets
                        .values()
                        .any(|metadata| validate_asset_sync_state(metadata).is_err())
            })
        {
            return Err(PlatformError::InvalidSyncState);
        }
        Ok(document)
    }
}

fn validate_asset_sync_state(metadata: &AssetSyncState) -> Result<(), PlatformError> {
    if metadata.remote_id == 0
        || metadata.vector_clock.len() > 64 * 1024
        || metadata.vector_clock.contains('\0')
        || !matches!(metadata.state.as_str(), "active" | "deleted" | "purged")
        || metadata
            .local_fingerprint
            .as_ref()
            .is_some_and(|fingerprint| {
                fingerprint.len() != 64 || !fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit())
            })
    {
        Err(PlatformError::InvalidSyncState)
    } else {
        let clock = serde_json::from_str::<HashMap<String, i64>>(&metadata.vector_clock)
            .map_err(|_| PlatformError::InvalidSyncState)?;
        if clock.len() > 128 || clock.values().any(|value| *value < 0) {
            Err(PlatformError::InvalidSyncState)
        } else {
            Ok(())
        }
    }
}

/// Returns a stable digest of non-secret local asset fields. This prevents a stored
/// remote revision from masking later local edits without persisting any credential.
pub fn asset_sync_fingerprint(asset: &ServerAsset) -> Result<String, PlatformError> {
    let encoded = serde_json::to_vec(asset)?;
    Ok(format!("{:x}", Sha256::digest(encoded)))
}

fn validate_account_fingerprint(value: &str) -> Result<(), PlatformError> {
    if value.len() == 12 && value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(PlatformError::InvalidAccountFingerprint)
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CredentialMaterial {
    pub password: String,
    pub private_key: String,
    pub private_key_passphrase: String,
}

impl CredentialMaterial {
    pub fn password(password: impl Into<String>) -> Self {
        Self {
            password: password.into(),
            private_key: String::new(),
            private_key_passphrase: String::new(),
        }
    }

    pub fn validate(&self) -> Result<(), PlatformError> {
        if (self.password.is_empty() && self.private_key.is_empty())
            || self.password.len() > 16 * 1024
            || self.private_key.len() > 1024 * 1024
            || self.private_key_passphrase.len() > 16 * 1024
            || self.password.contains('\0')
            || self.private_key.contains('\0')
            || self.private_key_passphrase.contains('\0')
        {
            return Err(PlatformError::InvalidCredential);
        }
        Ok(())
    }
}

impl Drop for CredentialMaterial {
    fn drop(&mut self) {
        self.password.zeroize();
        self.private_key.zeroize();
        self.private_key_passphrase.zeroize();
    }
}

#[derive(Clone, Default)]
pub struct CredentialVault;

impl CredentialVault {
    pub async fn store(
        &self,
        credential_id: Uuid,
        asset_name: &str,
        credential: &CredentialMaterial,
    ) -> Result<(), PlatformError> {
        credential.validate()?;
        let schema = credential_schema();
        let id = credential_id.simple().to_string();
        let attributes = credential_attributes(&id);
        let mut encoded = serde_json::to_string(credential)?;
        let label = format!("OrbitTerm — {}", asset_name.trim());
        let result = libsecret::password_store_future(
            Some(&schema),
            attributes,
            Some(libsecret::COLLECTION_DEFAULT.as_str()),
            &label,
            &encoded,
        )
        .await
        .map_err(|error| PlatformError::Keyring(error.to_string()));
        encoded.zeroize();
        result
    }

    pub async fn lookup(
        &self,
        credential_id: Uuid,
    ) -> Result<Option<CredentialMaterial>, PlatformError> {
        let schema = credential_schema();
        let id = credential_id.simple().to_string();
        let attributes = credential_attributes(&id);
        let value = libsecret::password_lookup_future(Some(&schema), attributes)
            .await
            .map_err(|error| PlatformError::Keyring(error.to_string()))?;
        value
            .map(|encoded| serde_json::from_str(encoded.as_str()).map_err(PlatformError::from))
            .transpose()
    }

    pub async fn clear(&self, credential_id: Uuid) -> Result<(), PlatformError> {
        let schema = credential_schema();
        let id = credential_id.simple().to_string();
        libsecret::password_clear_future(Some(&schema), credential_attributes(&id))
            .await
            .map_err(|error| PlatformError::Keyring(error.to_string()))
    }
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthTokenMaterial {
    pub access_token: String,
    pub refresh_token: String,
    #[serde(default)]
    pub account_scope: String,
}

impl AuthTokenMaterial {
    pub fn validate(&self) -> Result<(), PlatformError> {
        if self.access_token.is_empty()
            || self.access_token.len() > 16 * 1024
            || self.refresh_token.len() > 16 * 1024
            || self.access_token.contains('\0')
            || self.refresh_token.contains('\0')
            || self.account_scope.len() > 128
            || self.account_scope.contains('\0')
        {
            return Err(PlatformError::InvalidAuthToken);
        }
        Ok(())
    }
}

impl Drop for AuthTokenMaterial {
    fn drop(&mut self) {
        self.access_token.zeroize();
        self.refresh_token.zeroize();
        self.account_scope.zeroize();
    }
}

#[derive(Clone, Default)]
pub struct AuthTokenVault;

impl AuthTokenVault {
    pub async fn store(&self, tokens: &AuthTokenMaterial) -> Result<(), PlatformError> {
        tokens.validate()?;
        let schema = auth_token_schema();
        let attributes = HashMap::from([
            ("application", "com.orbitterm.Client"),
            ("account", "active"),
        ]);
        let mut encoded = serde_json::to_string(tokens)?;
        let result = libsecret::password_store_future(
            Some(&schema),
            attributes,
            Some(libsecret::COLLECTION_DEFAULT.as_str()),
            "OrbitTerm — 云同步登录",
            &encoded,
        )
        .await
        .map_err(|error| PlatformError::Keyring(error.to_string()));
        encoded.zeroize();
        result
    }

    pub async fn lookup(&self) -> Result<Option<AuthTokenMaterial>, PlatformError> {
        let schema = auth_token_schema();
        let attributes = HashMap::from([
            ("application", "com.orbitterm.Client"),
            ("account", "active"),
        ]);
        let value = libsecret::password_lookup_future(Some(&schema), attributes)
            .await
            .map_err(|error| PlatformError::Keyring(error.to_string()))?;
        value
            .map(|encoded| serde_json::from_str(encoded.as_str()).map_err(PlatformError::from))
            .transpose()
    }

    pub async fn clear(&self) -> Result<(), PlatformError> {
        let schema = auth_token_schema();
        libsecret::password_clear_future(
            Some(&schema),
            HashMap::from([
                ("application", "com.orbitterm.Client"),
                ("account", "active"),
            ]),
        )
        .await
        .map_err(|error| PlatformError::Keyring(error.to_string()))
    }
}

fn auth_token_schema() -> libsecret::Schema {
    libsecret::Schema::new(
        "com.orbitterm.Client.AuthToken",
        libsecret::SchemaFlags::NONE,
        HashMap::from([
            ("application", libsecret::SchemaAttributeType::String),
            ("account", libsecret::SchemaAttributeType::String),
        ]),
    )
}

fn credential_schema() -> libsecret::Schema {
    libsecret::Schema::new(
        "com.orbitterm.Client.Credential",
        libsecret::SchemaFlags::NONE,
        HashMap::from([
            ("application", libsecret::SchemaAttributeType::String),
            ("credential_id", libsecret::SchemaAttributeType::String),
        ]),
    )
}

fn credential_attributes(credential_id: &str) -> HashMap<&str, &str> {
    HashMap::from([
        ("application", "com.orbitterm.Client"),
        ("credential_id", credential_id),
    ])
}

pub fn ensure_known_hosts_parent(path: &Path) -> Result<(), PlatformError> {
    let parent = path.parent().ok_or(PlatformError::InvalidPath)?;
    secure_directory(parent)?;
    Ok(())
}

pub fn ensure_private_directory(path: &Path) -> Result<(), PlatformError> {
    secure_directory(path)
}

fn secure_atomic_json_write<T: serde::Serialize + ?Sized>(
    path: &Path,
    value: &T,
) -> Result<(), PlatformError> {
    let parent = path.parent().ok_or(PlatformError::InvalidPath)?;
    secure_directory(parent)?;
    reject_symlink(path)?;
    let bytes = serde_json::to_vec_pretty(value)?;
    let mut temporary = tempfile::Builder::new()
        .prefix(".orbitterm-assets-")
        .tempfile_in(parent)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    temporary.write_all(&bytes)?;
    temporary.write_all(b"\n")?;
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|error| error.error)?;
    fs::File::open(parent)?.sync_all()?;
    Ok(())
}

fn secure_directory(path: &Path) -> Result<(), PlatformError> {
    if path.exists() {
        reject_symlink(path)?;
        if !path.is_dir() {
            return Err(PlatformError::InvalidPath);
        }
        return Ok(());
    }
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn reject_symlink(path: &Path) -> Result<(), PlatformError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(PlatformError::SymlinkRefused),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

#[derive(Debug, Error)]
pub enum PlatformError {
    #[error("HOME 不可用或不是绝对路径")]
    HomeUnavailable,
    #[error("路径无效")]
    InvalidPath,
    #[error("拒绝使用符号链接作为安全存储路径")]
    SymlinkRefused,
    #[error("凭据必须包含密码或私钥，且大小与字符必须合法")]
    InvalidCredential,
    #[error("同步登录令牌无效")]
    InvalidAuthToken,
    #[error("同步账户指纹无效")]
    InvalidAccountFingerprint,
    #[error("同步状态文件无效")]
    InvalidSyncState,
    #[error("应用偏好设置无效")]
    InvalidPreferences,
    #[error("端口映射配置库无效")]
    InvalidPortForwardProfiles,
    #[error("命令片段库无效")]
    InvalidSnippets,
    #[error("同步状态中的账户数量超过安全限制")]
    TooManySyncAccounts,
    #[error("同步状态中的资产数量超过安全限制")]
    TooManySyncAssets,
    #[error("离线同步操作文件无效")]
    InvalidSyncOperations,
    #[error("离线同步队列已达到安全上限")]
    TooManySyncOperations,
    #[error("离线同步操作不存在")]
    SyncOperationNotFound,
    #[error("系统时钟不合法")]
    SystemClockInvalid,
    #[error("系统密钥环操作失败：{0}")]
    Keyring(String),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;
    use orbit_linux_application::AssetRepository;

    #[test]
    fn paths_follow_xdg_layout() {
        let paths = XdgPaths::from_bases(
            "/tmp/config".into(),
            "/tmp/data".into(),
            "/tmp/state".into(),
            "/tmp/cache".into(),
        );
        assert_eq!(
            paths.assets_file(),
            PathBuf::from("/tmp/data/OrbitTerm/assets.json")
        );
        assert_eq!(
            paths.known_hosts_file(),
            PathBuf::from("/tmp/state/OrbitTerm/security/known_hosts")
        );
        assert_eq!(
            paths.sync_state_file(),
            PathBuf::from("/tmp/state/OrbitTerm/sync/state.json")
        );
        assert_eq!(
            paths.sync_operations_file(),
            PathBuf::from("/tmp/state/OrbitTerm/sync/operations.json")
        );
        assert_eq!(
            paths.preferences_file(),
            PathBuf::from("/tmp/config/OrbitTerm/preferences.json")
        );
        assert_eq!(
            paths.port_forward_profiles_file(),
            PathBuf::from("/tmp/data/OrbitTerm/port-forward-profiles.json")
        );
        assert_eq!(
            paths.snippets_file(),
            PathBuf::from("/tmp/data/OrbitTerm/snippets.json")
        );
    }

    #[test]
    fn preferences_are_validated_and_owner_only() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config/preferences.json");
        let repository = PreferencesRepository::new(path.clone());
        let mut preferences = AppPreferences {
            terminal_font_size: 15,
            ..AppPreferences::default()
        };
        repository.save(&preferences).unwrap();
        assert_eq!(repository.load().unwrap(), preferences);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        preferences.monitor_refresh_seconds = 3;
        assert!(matches!(
            repository.save(&preferences),
            Err(PlatformError::InvalidPreferences)
        ));
    }

    #[test]
    fn port_forward_profiles_are_validated_and_owner_only() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data/port-forward-profiles.json");
        let repository = PortForwardProfileRepository::new(path.clone());
        let profile = PortForwardProfile {
            id: Uuid::new_v4(),
            asset_id: Uuid::new_v4(),
            name: "数据库".into(),
            bind_host: "127.0.0.1".into(),
            bind_port: 0,
            destination_host: "127.0.0.1".into(),
            destination_port: 5432,
            end_to_end_sync: false,
        };
        repository.upsert(profile.clone()).unwrap();
        assert_eq!(repository.load().unwrap(), vec![profile.clone()]);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let invalid = PortForwardProfile {
            destination_host: "bad host".into(),
            ..profile
        };
        assert!(matches!(
            repository.upsert(invalid),
            Err(PlatformError::InvalidPortForwardProfiles)
        ));
    }

    #[test]
    fn snippets_are_scoped_persisted_and_owner_only() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("data/snippets.json");
        let repository = SnippetRepository::new(path.clone());
        let asset_id = Uuid::new_v4();
        let snippet = CommandSnippet {
            id: Uuid::new_v4(),
            title: "查看监听端口".into(),
            command: "ss -lntup".into(),
            category: "网络".into(),
            asset_scope: SnippetAssetScope {
                mode: SnippetScopeMode::SelectedAssets,
                asset_ids: vec![asset_id],
            },
            created_at_unix_ms: 1,
            updated_at_unix_ms: 1,
        };
        repository.upsert(snippet.clone()).unwrap();
        assert_eq!(repository.load().unwrap(), vec![snippet.clone()]);
        assert!(snippet.applies_to(asset_id));
        assert!(!snippet.applies_to(Uuid::new_v4()));
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        repository.remove(snippet.id).unwrap();
        assert!(repository.load().unwrap().is_empty());
    }

    #[test]
    fn snippets_reject_empty_scope_and_duplicate_assets() {
        let now = 1;
        let base = CommandSnippet {
            id: Uuid::new_v4(),
            title: "诊断".into(),
            command: "uname -a".into(),
            category: String::new(),
            asset_scope: SnippetAssetScope {
                mode: SnippetScopeMode::SelectedAssets,
                asset_ids: Vec::new(),
            },
            created_at_unix_ms: now,
            updated_at_unix_ms: now,
        };
        assert!(matches!(
            base.validate(),
            Err(PlatformError::InvalidSnippets)
        ));
        let asset_id = Uuid::new_v4();
        let duplicate = CommandSnippet {
            asset_scope: SnippetAssetScope {
                mode: SnippetScopeMode::SelectedAssets,
                asset_ids: vec![asset_id, asset_id],
            },
            ..base
        };
        assert!(matches!(
            duplicate.validate(),
            Err(PlatformError::InvalidSnippets)
        ));
    }

    #[test]
    fn asset_file_is_owner_only_and_contains_no_credentials() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("data/OrbitTerm/assets.json");
        let repository = JsonAssetRepository::new(path.clone());
        repository
            .save(&[ServerAsset::new("节点", "host.example", "ops")])
            .expect("save");
        let mode = fs::metadata(&path).expect("metadata").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let contents = fs::read_to_string(path).expect("read");
        let assets: serde_json::Value = serde_json::from_str(&contents).expect("valid JSON");
        let asset = assets[0].as_object().expect("asset object");
        for forbidden in ["password", "privateKeyContent", "privateKeyPassphrase"] {
            assert!(!asset.contains_key(forbidden));
        }
    }

    #[test]
    fn auth_tokens_require_access_token_and_never_accept_nul() {
        let missing = AuthTokenMaterial::default();
        assert!(matches!(
            missing.validate(),
            Err(PlatformError::InvalidAuthToken)
        ));
        let valid = AuthTokenMaterial {
            access_token: "header.payload.signature".into(),
            refresh_token: "refresh".into(),
            account_scope: "a".repeat(64),
        };
        assert!(valid.validate().is_ok());
        let invalid = AuthTokenMaterial {
            access_token: "token\0suffix".into(),
            refresh_token: String::new(),
            account_scope: String::new(),
        };
        assert!(matches!(
            invalid.validate(),
            Err(PlatformError::InvalidAuthToken)
        ));
    }

    #[test]
    fn sync_state_is_owner_only_stable_and_partitioned_by_account() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("state/OrbitTerm/sync/state.json");
        let repository = SyncStateRepository::new(path.clone());
        let first_device = repository.device_id().expect("device id");
        assert!(!first_device.is_nil());
        assert_eq!(repository.cursor("001122aabbcc").unwrap(), 0);
        repository.save_cursor("001122aabbcc", 41).unwrap();
        repository.save_cursor("ffeeddccbbaa", 9).unwrap();
        assert_eq!(repository.device_id().unwrap(), first_device);
        assert_eq!(repository.cursor("001122aabbcc").unwrap(), 41);
        assert_eq!(repository.cursor("ffeeddccbbaa").unwrap(), 9);
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let contents = fs::read_to_string(path).unwrap();
        assert!(!contents.contains("accessToken"));
        assert!(!contents.contains("refreshToken"));
    }

    #[test]
    fn sync_state_rejects_unpartitioned_account_keys() {
        let directory = tempfile::tempdir().unwrap();
        let repository = SyncStateRepository::new(directory.path().join("sync.json"));
        assert!(matches!(
            repository.save_cursor("user@example.com", 1),
            Err(PlatformError::InvalidAccountFingerprint)
        ));
    }

    #[test]
    fn per_asset_revision_only_satisfies_an_unchanged_local_asset() {
        let directory = tempfile::tempdir().unwrap();
        let repository = SyncStateRepository::new(directory.path().join("sync/state.json"));
        let asset = ServerAsset::new("生产", "prod.example", "ops");
        repository
            .save_asset(
                "001122aabbcc",
                asset.id,
                AssetSyncState {
                    remote_id: 7,
                    vector_clock: r#"{"linux":12}"#.into(),
                    state: "active".into(),
                    server_revision: 42,
                    applied: true,
                    local_fingerprint: Some(asset_sync_fingerprint(&asset).unwrap()),
                },
            )
            .unwrap();
        assert_eq!(
            repository
                .applied_revisions("001122aabbcc", std::slice::from_ref(&asset))
                .unwrap()
                .get(&asset.id),
            Some(&42)
        );
        let mut edited = asset.clone();
        edited.host = "changed.example".into();
        assert!(repository
            .applied_revisions("001122aabbcc", &[edited])
            .unwrap()
            .is_empty());
        assert_eq!(
            repository
                .asset("001122aabbcc", asset.id)
                .unwrap()
                .unwrap()
                .remote_id,
            7
        );
    }

    #[test]
    fn sync_state_accepts_a_terminal_purged_tombstone() {
        let directory = tempfile::tempdir().unwrap();
        let repository = SyncStateRepository::new(directory.path().join("sync/state.json"));
        let asset_id = Uuid::new_v4();

        repository
            .save_asset(
                "001122aabbcc",
                asset_id,
                AssetSyncState {
                    remote_id: 9,
                    vector_clock: r#"{"apple":4}"#.into(),
                    state: "purged".into(),
                    server_revision: 51,
                    applied: true,
                    local_fingerprint: None,
                },
            )
            .unwrap();

        assert_eq!(
            repository
                .asset("001122aabbcc", asset_id)
                .unwrap()
                .unwrap()
                .state,
            "purged"
        );
    }

    #[test]
    fn legacy_sync_state_without_asset_map_remains_readable() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("sync/state.json");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            format!(
                r#"{{"version":1,"deviceId":"{}","accounts":{{"001122aabbcc":{{"cursor":9}}}}}}"#,
                Uuid::new_v4()
            ),
        )
        .unwrap();
        let repository = SyncStateRepository::new(path);
        assert_eq!(repository.cursor("001122aabbcc").unwrap(), 9);
        assert!(repository
            .applied_revisions("001122aabbcc", &[])
            .unwrap()
            .is_empty());
    }
}
