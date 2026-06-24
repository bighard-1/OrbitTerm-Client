use std::fs;
use std::io;
use std::path::{Component, Path};

use thiserror::Error;

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use super::host_key_challenge_registry::PendingHostKeyChallengeSnapshot;
use super::known_hosts_store::{AddTrustedKeyOutcome, KnownHostsStore, KnownHostsStoreError};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HostKeyTrustPersistenceError {
    #[error("OrbitTerm known_hosts path is invalid")]
    InvalidPath,
    #[error("OrbitTerm known_hosts parent directory could not be created ({kind:?})")]
    ParentDirectoryCreateFailed { kind: io::ErrorKind },
    #[error("OrbitTerm known_hosts parent directory permissions could not be set ({kind:?})")]
    ParentPermissionFailed { kind: io::ErrorKind },
    #[error("OrbitTerm known_hosts operation failed")]
    Store(#[source] KnownHostsStoreError),
}

impl From<KnownHostsStoreError> for HostKeyTrustPersistenceError {
    fn from(error: KnownHostsStoreError) -> Self {
        Self::Store(error)
    }
}

pub fn persist_snapshot_to_known_hosts(
    snapshot: &PendingHostKeyChallengeSnapshot,
    path: &Path,
    comment: Option<&str>,
) -> Result<AddTrustedKeyOutcome, HostKeyTrustPersistenceError> {
    validate_orbitterm_known_hosts_path(path)?;
    let mut store = KnownHostsStore::load(path)?;
    let outcome = store.add_trusted_key(
        &snapshot.host_identity,
        &snapshot.key_algorithm,
        snapshot.public_key_base64(),
        comment,
    )?;
    if outcome == AddTrustedKeyOutcome::Added {
        ensure_parent_directory(path)?;
        store.save(path)?;
    }
    Ok(outcome)
}

pub(crate) fn validate_orbitterm_known_hosts_path(
    path: &Path,
) -> Result<(), HostKeyTrustPersistenceError> {
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(HostKeyTrustPersistenceError::InvalidPath);
    }

    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .ok_or(HostKeyTrustPersistenceError::InvalidPath)?;
    let mut has_orbitterm_component = false;
    for component in parent.components() {
        match component {
            Component::ParentDir | Component::CurDir => {
                return Err(HostKeyTrustPersistenceError::InvalidPath);
            }
            Component::Normal(value) => {
                let normalized = value.to_string_lossy().to_ascii_lowercase();
                if normalized == ".ssh" {
                    return Err(HostKeyTrustPersistenceError::InvalidPath);
                }
                has_orbitterm_component |= normalized.contains("orbitterm");
            }
            Component::Prefix(_) | Component::RootDir => {}
        }
    }

    if !has_orbitterm_component {
        return Err(HostKeyTrustPersistenceError::InvalidPath);
    }
    Ok(())
}

fn ensure_parent_directory(path: &Path) -> Result<(), HostKeyTrustPersistenceError> {
    let parent = path
        .parent()
        .filter(|value| !value.as_os_str().is_empty())
        .ok_or(HostKeyTrustPersistenceError::InvalidPath)?;
    let parent_existed = match fs::symlink_metadata(parent) {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(HostKeyTrustPersistenceError::InvalidPath);
            }
            true
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(HostKeyTrustPersistenceError::ParentDirectoryCreateFailed {
                kind: error.kind(),
            });
        }
    };

    if !parent_existed {
        fs::create_dir_all(parent).map_err(|error| {
            HostKeyTrustPersistenceError::ParentDirectoryCreateFailed { kind: error.kind() }
        })?;
        #[cfg(unix)]
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).map_err(|error| {
            HostKeyTrustPersistenceError::ParentPermissionFailed { kind: error.kind() }
        })?;
    }
    Ok(())
}
