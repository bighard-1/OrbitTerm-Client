use std::sync::Arc;

use regex::Regex;
use russh_sftp::protocol::OpenFlags;
use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};

use crate::{run_remote_command, OrbitCoreError, OrbitSftpSession};

const SFTP_IO_BUF_SIZE: usize = 64 * 1024;

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
            SftpListItem {
                name: entry.file_name(),
                size: metadata.size.unwrap_or(0),
                permissions: metadata.permissions().to_string(),
                permissions_octal: metadata.permissions.unwrap_or(0),
                modified_at_unix: metadata.mtime.unwrap_or(0) as u64,
            }
        })
        .collect();

    eprintln!(
        "[orbit-core][sftp_list_dir] session={} path={} items={}",
        session_id,
        path_for_log,
        items.len()
    );

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

        eprintln!(
            "[orbit-core][sftp_upload_file] session={} chunk_bytes={} remote={}",
            session_id, n, remote_for_log
        );

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

        eprintln!(
            "[orbit-core][sftp_download_file] session={} chunk_bytes={} remote={}",
            session_id, n, remote_for_log
        );

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

pub(crate) async fn mkdir(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let cmd = format!("mkdir -p -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command(&session.base, &cmd).await?;
    Ok(())
}

pub(crate) async fn create_file(
    session: &Arc<OrbitSftpSession>,
    remote_path: String,
) -> Result<(), OrbitCoreError> {
    if remote_path.trim().is_empty() {
        return Err(OrbitCoreError::InvalidInput);
    }
    let cmd = format!("touch -- {}", shell_single_quote(remote_path.trim()));
    let _ = run_remote_command(&session.base, &cmd).await?;
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
    let _ = run_remote_command(&session.base, &cmd).await?;
    Ok(())
}

fn shell_single_quote(input: &str) -> String {
    format!("'{}'", input.replace('\'', "'\"'\"'"))
}
