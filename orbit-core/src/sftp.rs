use std::sync::Arc;

use regex::Regex;
use russh_sftp::protocol::{FileAttributes, OpenFlags};
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

use crate::{run_remote_command_for_sftp_operation, OrbitCoreError, OrbitSftpSession};

const SFTP_IO_BUF_SIZE: usize = 64 * 1024;
const SFTP_TEXT_EDIT_MAX_BYTES: usize = 2 * 1024 * 1024;
const SFTP_TEXT_NEW_SUFFIX: &str = ".orbitterm-new";
const SFTP_TEXT_BACKUP_SUFFIX: &str = ".orbitterm-backup";

#[derive(Debug, Serialize)]
struct SftpListItem {
    name: String,
    size: u64,
    permissions: String,
    permissions_octal: u32,
    modified_at_unix: u64,
}

#[derive(Debug, Serialize)]
struct SftpTransferResult {
    bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SftpEntrySnapshot {
    pub(crate) size: u64,
    pub(crate) permissions_octal: u32,
    pub(crate) modified_at_unix: u64,
    pub(crate) is_directory: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SftpMutationError {
    InvalidRequest,
    SessionUnavailable,
    TargetExists,
    EntryChanged,
    BackendFailed,
}

pub(crate) async fn list_dir(
    session_id: u64,
    session: &Arc<OrbitSftpSession>,
    path: String,
) -> Result<String, OrbitCoreError> {
    if path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let path_for_log = path.clone();
    let entries = session
        .sftp
        .read_dir(path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))?;

    let items: Vec<SftpListItem> = entries
        .map(|entry| {
            let metadata = entry.metadata();
            let type_prefix = if metadata.is_dir() {
                'd'
            } else if metadata.is_symlink() {
                'l'
            } else if metadata.is_regular() {
                '-'
            } else {
                '?'
            };
            SftpListItem {
                name: entry.file_name(),
                size: metadata.size.unwrap_or(0),
                permissions: format!("{}{}", type_prefix, metadata.permissions()),
                permissions_octal: metadata.permissions.unwrap_or(0),
                modified_at_unix: metadata.mtime.unwrap_or(0) as u64,
            }
        })
        .collect();

    if std::env::var_os("ORBIT_CORE_DEBUG").is_some() {
        eprintln!(
            "[orbit-core][sftp_list_dir] session={} path={} items={}",
            session_id,
            path_for_log,
            items.len()
        );
    }

    serde_json::to_string(&items).map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn upload_file(
    session_id: u64,
    session: &Arc<OrbitSftpSession>,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut local = tokio::fs::File::open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open local file failed: {e}")))?;

    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let mut buf = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut total: u64 = 0;

    loop {
        let n = local
            .read(&mut buf)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read local file failed: {e}")))?;
        if n == 0 {
            break;
        }

        if std::env::var_os("ORBIT_CORE_DEBUG").is_some() {
            eprintln!(
                "[orbit-core][sftp_upload_file] session={} chunk_bytes={} remote={}",
                session_id, n, remote_for_log
            );
        }

        remote
            .write_all(&buf[..n])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write remote file failed: {e}")))?;
        total += n as u64;
    }

    remote
        .shutdown()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("shutdown remote file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult { bytes: total })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn upload_file_create_new(
    session_id: u64,
    session: &Arc<OrbitSftpSession>,
    local_path: String,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let metadata = tokio::fs::metadata(&local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("stat local file failed: {e}")))?;
    if !metadata.is_file() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut local = tokio::fs::File::open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open local file failed: {e}")))?;
    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("create remote file failed: {e}")))?;

    let mut buffer = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut uploaded: u64 = 0;
    loop {
        let count = local
            .read(&mut buffer)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read local file failed: {e}")))?;
        if count == 0 {
            break;
        }
        if std::env::var_os("ORBIT_CORE_DEBUG").is_some() {
            eprintln!(
                "[orbit-core][sftp_upload_checked] session={} chunk_bytes={} remote={}",
                session_id, count, remote_for_log
            );
        }
        remote
            .write_all(&buffer[..count])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write remote file failed: {e}")))?;
        uploaded += count as u64;
    }

    remote
        .shutdown()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("shutdown remote file failed: {e}")))?;
    serde_json::to_string(&SftpTransferResult { bytes: uploaded })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn download_file(
    session_id: u64,
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    local_path: String,
    resume_offset: u64,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    if resume_offset > 0 {
        remote
            .seek(std::io::SeekFrom::Start(resume_offset))
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("seek remote failed: {e}")))?;
    }

    let mut local = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .read(true)
        .truncate(false)
        .open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open local file failed: {e}")))?;

    if resume_offset == 0 {
        local
            .set_len(0)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("truncate local file failed: {e}")))?;
    }

    local
        .seek(std::io::SeekFrom::Start(resume_offset))
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("seek local failed: {e}")))?;

    let mut buf = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut downloaded: u64 = 0;

    loop {
        let n = remote
            .read(&mut buf)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read remote file failed: {e}")))?;
        if n == 0 {
            break;
        }

        if std::env::var_os("ORBIT_CORE_DEBUG").is_some() {
            eprintln!(
                "[orbit-core][sftp_download_file] session={} chunk_bytes={} remote={}",
                session_id, n, remote_for_log
            );
        }

        local
            .write_all(&buf[..n])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write local file failed: {e}")))?;
        downloaded += n as u64;
    }

    local
        .flush()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("flush local file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult { bytes: downloaded })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn download_file_create_new(
    session_id: u64,
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    local_path: String,
) -> Result<String, OrbitCoreError> {
    if local_path.trim().is_empty() || remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let remote_for_log = remote_path.clone();
    let mut remote = session
        .sftp
        .open(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;
    let mut local = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(local_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("create local file failed: {e}")))?;

    let mut buf = vec![0u8; SFTP_IO_BUF_SIZE];
    let mut downloaded: u64 = 0;
    loop {
        let n = remote
            .read(&mut buf)
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("read remote file failed: {e}")))?;
        if n == 0 {
            break;
        }
        if std::env::var_os("ORBIT_CORE_DEBUG").is_some() {
            eprintln!(
                "[orbit-core][sftp_download_checked] session={} chunk_bytes={} remote={}",
                session_id, n, remote_for_log
            );
        }
        local
            .write_all(&buf[..n])
            .await
            .map_err(|e| OrbitCoreError::SftpFailed(format!("write local file failed: {e}")))?;
        downloaded += n as u64;
    }
    local
        .flush()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("flush local file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult { bytes: downloaded })
        .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn read_text_file(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<String, OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut remote = session
        .sftp
        .open(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let mut data = Vec::new();
    remote
        .read_to_end(&mut data)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("read remote file failed: {e}")))?;

    if data.len() > 2 * 1024 * 1024 {
        return Err(OrbitCoreError::SftpFailed(
            "文件超过 2MB，暂不支持在线编辑".to_string(),
        ));
    }

    String::from_utf8(data).map_err(|_| {
        OrbitCoreError::SftpFailed("文件不是 UTF-8 文本，暂不支持在线编辑".to_string())
    })
}

pub(crate) async fn write_text_file(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    content: String,
) -> Result<String, OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::TRUNCATE | OpenFlags::WRITE,
        )
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("open remote file failed: {e}")))?;

    let bytes = content.into_bytes();
    remote
        .write_all(&bytes)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("write remote file failed: {e}")))?;
    remote
        .shutdown()
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(format!("shutdown remote file failed: {e}")))?;

    serde_json::to_string(&SftpTransferResult {
        bytes: bytes.len() as u64,
    })
    .map_err(|e| OrbitCoreError::Internal(e.to_string()))
}

pub(crate) async fn write_text_file_checked_recoverable(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    content: Vec<u8>,
    expected: SftpEntrySnapshot,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&remote_path)
        || content.len() > SFTP_TEXT_EDIT_MAX_BYTES
        || std::str::from_utf8(&content).is_err()
        || expected.is_directory
        || expected.permissions_octal & 0o170_000 != 0o100_000
    {
        return Err(SftpMutationError::InvalidRequest);
    }

    let new_path = format!("{remote_path}{SFTP_TEXT_NEW_SUFFIX}");
    let backup_path = format!("{remote_path}{SFTP_TEXT_BACKUP_SUFFIX}");
    if new_path.len() > 512 || backup_path.len() > 512 {
        return Err(SftpMutationError::InvalidRequest);
    }
    for path in [&new_path, &backup_path] {
        if session
            .sftp
            .try_exists(path.clone())
            .await
            .map_err(|_| SftpMutationError::BackendFailed)?
        {
            return Err(SftpMutationError::TargetExists);
        }
    }

    let mut temporary = session
        .sftp
        .open_with_flags(
            new_path.clone(),
            OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
        )
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?;
    let staged = async {
        temporary
            .set_metadata(FileAttributes {
                permissions: Some(expected.permissions_octal),
                ..FileAttributes::empty()
            })
            .await
            .map_err(|_| SftpMutationError::BackendFailed)?;
        temporary
            .write_all(&content)
            .await
            .map_err(|_| SftpMutationError::BackendFailed)?;
        temporary
            .shutdown()
            .await
            .map_err(|_| SftpMutationError::BackendFailed)
    }
    .await;
    if let Err(error) = staged {
        let _ = session.sftp.remove_file(new_path).await;
        return Err(error);
    }

    if let Err(error) = verify_entry_snapshot(session, &remote_path, expected).await {
        let _ = session.sftp.remove_file(new_path).await;
        return Err(error);
    }
    if session
        .sftp
        .rename(remote_path.clone(), backup_path.clone())
        .await
        .is_err()
    {
        let _ = session.sftp.remove_file(new_path).await;
        return Err(SftpMutationError::BackendFailed);
    }
    if session
        .sftp
        .rename(new_path.clone(), remote_path.clone())
        .await
        .is_err()
    {
        let _rollback = session.sftp.rename(backup_path.clone(), remote_path).await;
        let _ = session.sftp.remove_file(new_path).await;
        return Err(SftpMutationError::BackendFailed);
    }

    let _ = session.sftp.remove_file(backup_path).await;
    Ok(())
}

pub(crate) async fn remove_file(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    if session.sftp.remove_file(remote_path.clone()).await.is_ok() {
        return Ok(());
    }

    // 兼容目录删除：先尝试删文件，失败后再尝试删空目录。
    session
        .sftp
        .remove_dir(remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))
}

pub(crate) async fn remove_checked(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    expected: SftpEntrySnapshot,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&remote_path) {
        return Err(SftpMutationError::InvalidRequest);
    }

    verify_entry_snapshot(session, &remote_path, expected).await?;
    let result = if expected.is_directory {
        session.sftp.remove_dir(remote_path).await
    } else {
        session.sftp.remove_file(remote_path).await
    };
    result.map_err(|_| SftpMutationError::BackendFailed)
}

pub(crate) async fn rename(
    session: &Arc<OrbitSftpSession>,
    old_remote_path: String,
    new_remote_path: String,
) -> Result<(), OrbitCoreError> {
    if old_remote_path.trim().is_empty() || new_remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }

    session
        .sftp
        .rename(old_remote_path, new_remote_path)
        .await
        .map_err(|e| OrbitCoreError::SftpFailed(e.to_string()))
}

pub(crate) async fn rename_checked_no_overwrite(
    session: &Arc<OrbitSftpSession>,
    old_remote_path: String,
    new_remote_path: String,
    expected: SftpEntrySnapshot,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&old_remote_path)
        || !is_canonical_mutation_path(&new_remote_path)
        || old_remote_path == new_remote_path
    {
        return Err(SftpMutationError::InvalidRequest);
    }

    verify_entry_snapshot(session, &old_remote_path, expected).await?;
    if session
        .sftp
        .try_exists(new_remote_path.clone())
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?
    {
        return Err(SftpMutationError::TargetExists);
    }

    session
        .sftp
        .rename(old_remote_path, new_remote_path)
        .await
        .map_err(|_| SftpMutationError::BackendFailed)
}

pub(crate) async fn mkdir(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let cmd = format!("mkdir -p -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command_for_sftp_operation(session, &cmd).await?;
    Ok(())
}

pub(crate) async fn mkdir_checked_create_new(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&remote_path) {
        return Err(SftpMutationError::InvalidRequest);
    }
    if session
        .sftp
        .try_exists(remote_path.clone())
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?
    {
        return Err(SftpMutationError::TargetExists);
    }
    session
        .sftp
        .create_dir(remote_path)
        .await
        .map_err(|_| SftpMutationError::BackendFailed)
}

pub(crate) async fn create_file_checked_create_new(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&remote_path) {
        return Err(SftpMutationError::InvalidRequest);
    }
    if session
        .sftp
        .try_exists(remote_path.clone())
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?
    {
        return Err(SftpMutationError::TargetExists);
    }
    let mut remote = session
        .sftp
        .open_with_flags(
            remote_path,
            OpenFlags::CREATE | OpenFlags::EXCLUDE | OpenFlags::WRITE,
        )
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?;
    remote
        .shutdown()
        .await
        .map_err(|_| SftpMutationError::BackendFailed)
}

pub(crate) async fn chmod_checked(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    mode: u32,
    expected: SftpEntrySnapshot,
) -> Result<(), SftpMutationError> {
    if !is_canonical_mutation_path(&remote_path) || mode > 0o7777 {
        return Err(SftpMutationError::InvalidRequest);
    }
    verify_entry_snapshot(session, &remote_path, expected).await?;

    let file_type = expected.permissions_octal & 0o170_000;
    if !matches!(file_type, 0o040_000 | 0o100_000) {
        return Err(SftpMutationError::InvalidRequest);
    }
    let metadata = FileAttributes {
        permissions: Some(file_type | mode),
        ..FileAttributes::empty()
    };
    session
        .sftp
        .set_metadata(remote_path.clone(), metadata)
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?;

    let updated = session
        .sftp
        .symlink_metadata(remote_path)
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?;
    if updated.permissions.unwrap_or(0) & 0o7777 != mode {
        return Err(SftpMutationError::BackendFailed);
    }
    Ok(())
}

async fn verify_entry_snapshot(
    session: &Arc<OrbitSftpSession>,
    remote_path: &str,
    expected: SftpEntrySnapshot,
) -> Result<(), SftpMutationError> {
    let metadata = session
        .sftp
        .symlink_metadata(remote_path.to_string())
        .await
        .map_err(|_| SftpMutationError::BackendFailed)?;
    let actual = SftpEntrySnapshot {
        size: metadata.size.unwrap_or(0),
        permissions_octal: metadata.permissions.unwrap_or(0),
        modified_at_unix: metadata.mtime.unwrap_or(0) as u64,
        is_directory: metadata.is_dir(),
    };
    if actual != expected {
        return Err(SftpMutationError::EntryChanged);
    }
    Ok(())
}

fn is_canonical_mutation_path(path: &str) -> bool {
    !path.trim().is_empty()
        && path.starts_with('/')
        && path != "/"
        && !path.ends_with('/')
        && !path
            .split('/')
            .skip(1)
            .any(|segment| segment.is_empty() || segment == "." || segment == "..")
}

pub(crate) async fn create_file(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let cmd = format!("touch -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command_for_sftp_operation(session, &cmd).await?;
    Ok(())
}

pub(crate) async fn chmod(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
    mode_octal: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let mode = mode_octal.trim();
    let mode_re =
        Regex::new(r"^[0-7]{3,4}$").map_err(|e| OrbitCoreError::Internal(e.to_string()))?;
    if !mode_re.is_match(mode) {
        return Err(OrbitCoreError::InvalidInput);
    }

    let cmd = format!(
        "chmod {} -- {}",
        mode,
        shell_single_quote(remote_path.trim())
    );
    let _ = run_remote_command_for_sftp_operation(session, &cmd).await?;
    Ok(())
}

fn shell_single_quote(input: &str) -> String {
    format!("'{}'", input.replace('\'', "'\"'\"'"))
}
