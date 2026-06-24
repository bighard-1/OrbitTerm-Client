use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use rand::random;

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use super::KnownHostsStoreError;

pub(super) struct LoadedKnownHostsFile {
    pub contents: String,
    pub insecure_mode: Option<u32>,
}

pub(super) fn read_file(
    path: &Path,
    max_file_size: usize,
) -> Result<Option<LoadedKnownHostsFile>, KnownHostsStoreError> {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(KnownHostsStoreError::ReadFailed { kind: error.kind() });
        }
    };

    if metadata.len() > max_file_size as u64 {
        return Err(KnownHostsStoreError::FileTooLarge {
            max_bytes: max_file_size,
        });
    }

    let file = File::open(path)
        .map_err(|error| KnownHostsStoreError::ReadFailed { kind: error.kind() })?;
    let mut bytes = Vec::with_capacity((metadata.len() as usize).min(max_file_size));
    file.take(max_file_size.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|error| KnownHostsStoreError::ReadFailed { kind: error.kind() })?;
    if bytes.len() > max_file_size {
        return Err(KnownHostsStoreError::FileTooLarge {
            max_bytes: max_file_size,
        });
    }

    let contents = String::from_utf8(bytes).map_err(|_| KnownHostsStoreError::InvalidUtf8)?;
    #[cfg(unix)]
    let insecure_mode = {
        let mode = metadata.permissions().mode() & 0o777;
        (mode & 0o077 != 0).then_some(mode)
    };
    #[cfg(not(unix))]
    let insecure_mode = None;

    Ok(Some(LoadedKnownHostsFile {
        contents,
        insecure_mode,
    }))
}

pub(super) fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), KnownHostsStoreError> {
    let (temporary_path, mut temporary_file) = create_temporary_file(path)?;
    let write_result = (|| {
        temporary_file
            .write_all(contents)
            .map_err(|error| KnownHostsStoreError::WriteFailed { kind: error.kind() })?;
        temporary_file
            .flush()
            .map_err(|error| KnownHostsStoreError::FlushFailed { kind: error.kind() })?;
        temporary_file
            .sync_all()
            .map_err(|error| KnownHostsStoreError::SyncFailed { kind: error.kind() })?;
        Ok::<(), KnownHostsStoreError>(())
    })();

    drop(temporary_file);
    if let Err(error) = write_result {
        let _ = fs::remove_file(&temporary_path);
        return Err(error);
    }

    if let Err(error) = fs::rename(&temporary_path, path) {
        let _ = fs::remove_file(&temporary_path);
        return Err(KnownHostsStoreError::AtomicReplaceFailed { kind: error.kind() });
    }

    #[cfg(unix)]
    if let Some(parent) = effective_parent(path) {
        if let Ok(directory) = File::open(parent) {
            let _ = directory.sync_all();
        }
    }

    Ok(())
}

fn create_temporary_file(path: &Path) -> Result<(PathBuf, File), KnownHostsStoreError> {
    let parent = effective_parent(path).ok_or(KnownHostsStoreError::InvalidPath)?;
    if path.file_name().is_none() {
        return Err(KnownHostsStoreError::InvalidPath);
    }

    for _ in 0..16 {
        let temporary_path = parent.join(format!(
            ".orbitterm-known-hosts-{}-{:016x}.tmp",
            std::process::id(),
            random::<u64>()
        ));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);

        match options.open(&temporary_path) {
            Ok(file) => {
                #[cfg(unix)]
                if let Err(error) =
                    fs::set_permissions(&temporary_path, fs::Permissions::from_mode(0o600))
                {
                    drop(file);
                    let _ = fs::remove_file(&temporary_path);
                    return Err(KnownHostsStoreError::PermissionFailed { kind: error.kind() });
                }
                return Ok((temporary_path, file));
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(KnownHostsStoreError::TemporaryFileCreateFailed { kind: error.kind() });
            }
        }
    }

    Err(KnownHostsStoreError::TemporaryFileCreateFailed {
        kind: io::ErrorKind::AlreadyExists,
    })
}

fn effective_parent(path: &Path) -> Option<&Path> {
    match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => Some(parent),
        Some(_) => Some(Path::new(".")),
        None => None,
    }
}
