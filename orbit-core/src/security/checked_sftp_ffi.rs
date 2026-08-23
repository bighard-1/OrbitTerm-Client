use std::collections::HashMap;
use std::ffi::CStr;
use std::future::Future;
use std::os::raw::c_char;
use std::path::Path;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde::Deserialize;

use super::host_key_ffi_api::{ffi_response, success_envelope};
use super::host_key_ffi_error::{HostKeyFfiErrorCode, HostKeyFfiErrorPayload};
use super::host_key_ffi_protocol::{
    validate_sftp_mutation_path, validate_sftp_path, HostKeyFfiResult, SftpChannelOpenedPayload,
    SftpDirectoryEntryPayload, SftpDirectoryListPayload, SftpDownloadPayload, SftpMutationPayload,
    SftpTextFilePayload, SftpUploadPayload,
};
use crate::checked_sftp::{discard_sftp_channel_checked, open_sftp_channel_checked, SftpSessionId};
use crate::security::CheckedChannelAccessError;
use crate::sftp::{SftpEntrySnapshot, SftpMutationError};
use crate::OrbitCoreError;
use crate::ORBIT_RUNTIME;

const MAX_REQUEST_ID_BYTES: usize = 256;
const MAX_SFTP_PATH_BYTES: usize = 512;
const MAX_LOCAL_DOWNLOAD_PATH_BYTES: usize = 4096;
const MAX_SFTP_TEXT_EDIT_BYTES: usize = 2 * 1024 * 1024;
const SFTP_PROGRESS_MIN_INTERVAL: Duration = Duration::from_millis(100);

static ACTIVE_SFTP_TRANSFERS: Lazy<Mutex<HashMap<String, Arc<AtomicBool>>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
type SftpProgressSink = Arc<dyn Fn(&str, u64, Option<u64>) + Send + Sync>;
static SFTP_PROGRESS_SINK: Lazy<Mutex<Option<SftpProgressSink>>> = Lazy::new(|| Mutex::new(None));

#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn install_sftp_progress_sink(sink: SftpProgressSink) {
    *SFTP_PROGRESS_SINK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(sink);
}

pub(crate) fn clear_sftp_progress_sink() {
    *SFTP_PROGRESS_SINK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

fn emit_sftp_progress(request_id: &str, transferred: u64, total: Option<u64>) {
    let sink = SFTP_PROGRESS_SINK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .as_ref()
        .cloned();
    if let Some(sink) = sink {
        sink(request_id, transferred, total);
    }
}

struct SftpTransferRegistration {
    request_id: String,
    cancelled: Arc<AtomicBool>,
}

impl SftpTransferRegistration {
    fn register(request_id: &str) -> Result<Self, ()> {
        let mut active = ACTIVE_SFTP_TRANSFERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Unit tests intentionally exercise identical fixture request ids in
        // parallel. Production rejects duplicates so one cancellation request
        // can never target an unrelated transfer.
        if active.contains_key(request_id) && !cfg!(test) {
            return Err(());
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        active.insert(request_id.to_string(), Arc::clone(&cancelled));
        Ok(Self {
            request_id: request_id.to_string(),
            cancelled,
        })
    }
}

impl Drop for SftpTransferRegistration {
    fn drop(&mut self) {
        let mut active = ACTIVE_SFTP_TRANSFERS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if active
            .get(&self.request_id)
            .is_some_and(|current| Arc::ptr_eq(current, &self.cancelled))
        {
            active.remove(&self.request_id);
        }
    }
}

#[no_mangle]
pub extern "C" fn orbit_sftp_open_checked_v1(
    base_session_id: u64,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_open_checked_response(base_session_id, request_id, open_sftp_channel_checked)
}

#[no_mangle]
pub extern "C" fn orbit_sftp_list_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_list_checked_response(
        sftp_session_id,
        remote_path,
        request_id,
        crate::sftp_list_dir,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_read_text_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_read_text_checked_response(
        sftp_session_id,
        remote_path,
        request_id,
        crate::sftp_read_text_file,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_download_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    local_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_download_checked_response(
        sftp_session_id,
        remote_path,
        local_path,
        request_id,
        |session_id, remote_path, local_path, cancelled, progress| async move {
            crate::sftp_download_file_create_new_cancellable(
                session_id,
                remote_path,
                local_path,
                &cancelled,
                &*progress,
            )
            .await
        },
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_upload_checked_v1(
    sftp_session_id: u64,
    local_path: *const c_char,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_upload_checked_response(
        sftp_session_id,
        local_path,
        remote_path,
        request_id,
        |session_id, local_path, remote_path, cancelled, progress| async move {
            crate::sftp_upload_file_create_new_cancellable(
                session_id,
                local_path,
                remote_path,
                &cancelled,
                &*progress,
            )
            .await
        },
    )
}

/// Requests cancellation of an active checked SFTP transfer. The request id is
/// the id supplied to upload/download, not a new RPC id. A true result means
/// the transfer will stop at its next I/O boundary; a just-completed transfer
/// deliberately returns false rather than reporting a stale cancellation.
#[no_mangle]
pub extern "C" fn orbit_sftp_cancel_checked_v1(request_id: *const c_char) -> bool {
    let Ok(request_id) = parse_request_id(request_id) else {
        return false;
    };
    let active = ACTIVE_SFTP_TRANSFERS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(cancelled) = active.get(&request_id) else {
        return false;
    };
    cancelled.store(true, Ordering::Release);
    true
}

#[no_mangle]
pub extern "C" fn orbit_sftp_mkdir_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_mkdir_checked_response(
        sftp_session_id,
        remote_path,
        request_id,
        crate::sftp_mkdir_checked_create_new,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_create_file_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_create_file_checked_response(
        sftp_session_id,
        remote_path,
        request_id,
        crate::sftp_create_file_checked_create_new,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_rename_checked_v1(
    sftp_session_id: u64,
    old_remote_path: *const c_char,
    new_remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_rename_checked_response(
        sftp_session_id,
        old_remote_path,
        new_remote_path,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        crate::sftp_rename_checked_no_overwrite,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_remove_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_remove_checked_response(
        sftp_session_id,
        remote_path,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        crate::sftp_remove_checked,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_chmod_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    mode: u32,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_chmod_checked_response(
        sftp_session_id,
        remote_path,
        mode,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        crate::sftp_chmod_checked,
    )
}

#[no_mangle]
pub extern "C" fn orbit_sftp_write_text_checked_v1(
    sftp_session_id: u64,
    remote_path: *const c_char,
    content_ptr: *const u8,
    content_len: usize,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
) -> *mut c_char {
    sftp_write_text_checked_response(
        sftp_session_id,
        remote_path,
        content_ptr,
        content_len,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        crate::sftp_write_text_file_checked_recoverable,
    )
}

fn sftp_open_checked_response<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<SftpSessionId, CheckedChannelAccessError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if base_session_id == 0 {
            return Err(invalid_request("invalid_base_session_id", Some(request_id)));
        }

        let sftp_session_id = ORBIT_RUNTIME
            .block_on(opener(base_session_id))
            .map_err(|error| {
                HostKeyFfiErrorPayload::from_checked_channel_error(error, Some(request_id.clone()))
            })?;
        let home_path = ORBIT_RUNTIME
            .block_on(crate::sftp_canonical_home_path_checked(
                sftp_session_id.get(),
            ))
            .unwrap_or_else(|_| "/".to_string());
        let envelope = (|| {
            let payload = SftpChannelOpenedPayload::new_with_home(
                base_session_id,
                sftp_session_id.get(),
                home_path,
            )
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
            let envelope = success_envelope(
                Some(request_id),
                HostKeyFfiResult::SftpChannelOpened(payload),
            )?;

            // Preflight serialization before publishing the opaque SFTP ID to C.
            envelope.to_json().map_err(|_| {
                HostKeyFfiErrorPayload::new(
                    HostKeyFfiErrorCode::FfiInternalError,
                    Some("sftp_open_response_serialization_failed"),
                    envelope.request_id.clone(),
                    None,
                )
            })?;
            Ok(envelope)
        })();
        if envelope.is_err() {
            ORBIT_RUNTIME.block_on(discard_sftp_channel_checked(sftp_session_id));
        }
        envelope
    })
}

fn sftp_list_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    lister: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if sftp_session_id == 0 {
            return Err(invalid_request("invalid_sftp_session_id", Some(request_id)));
        }

        let remote_path = parse_remote_path(remote_path, Some(request_id.clone()))?;
        let list_json = ORBIT_RUNTIME
            .block_on(lister(sftp_session_id, remote_path.clone()))
            .map_err(|error| sftp_list_error_payload(error, Some(request_id.clone())))?;
        let payload = directory_list_payload(sftp_session_id, remote_path, &list_json)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;

        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpDirectoryList(payload),
        )
    })
}

fn sftp_read_text_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    reader: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if sftp_session_id == 0 {
            return Err(invalid_request("invalid_sftp_session_id", Some(request_id)));
        }

        let remote_path = parse_remote_path(remote_path, Some(request_id.clone()))?;
        let content = ORBIT_RUNTIME
            .block_on(reader(sftp_session_id, remote_path.clone()))
            .map_err(|error| sftp_read_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpTextFilePayload::new(sftp_session_id, remote_path, content)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;

        success_envelope(Some(request_id), HostKeyFfiResult::SftpTextFile(payload))
    })
}

fn sftp_download_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    local_path: *const c_char,
    request_id: *const c_char,
    downloader: F,
) -> *mut c_char
where
    F: FnOnce(
        u64,
        String,
        String,
        Arc<AtomicBool>,
        Arc<dyn Fn(u64, Option<u64>) + Send + Sync>,
    ) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if sftp_session_id == 0 {
            return Err(invalid_request("invalid_sftp_session_id", Some(request_id)));
        }
        let remote_path = parse_remote_path(remote_path, Some(request_id.clone()))?;
        let local_path = parse_local_download_path(local_path, Some(request_id.clone()))?;
        let registration = SftpTransferRegistration::register(&request_id).map_err(|_| {
            invalid_request("duplicate_sftp_transfer_request", Some(request_id.clone()))
        })?;
        let progress_request_id = request_id.clone();
        let progress_last_emitted =
            Arc::new(Mutex::new(Instant::now() - SFTP_PROGRESS_MIN_INTERVAL));
        let progress = Arc::new(move |transferred: u64, total: Option<u64>| {
            let mut last_emitted = progress_last_emitted
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let is_complete = total.is_some_and(|total| transferred >= total);
            if transferred != 0
                && !is_complete
                && last_emitted.elapsed() < SFTP_PROGRESS_MIN_INTERVAL
            {
                return;
            }
            *last_emitted = Instant::now();
            emit_sftp_progress(&progress_request_id, transferred, total)
        });
        let transfer_json = ORBIT_RUNTIME
            .block_on(downloader(
                sftp_session_id,
                remote_path.clone(),
                local_path,
                Arc::clone(&registration.cancelled),
                progress,
            ))
            .map_err(|error| sftp_download_error_payload(error, Some(request_id.clone())))?;
        let transfer: SftpTransferResult = serde_json::from_str(&transfer_json).map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::FfiInternalError,
                Some("sftp_download_response_invalid"),
                Some(request_id.clone()),
                None,
            )
        })?;
        let payload = SftpDownloadPayload::new(sftp_session_id, remote_path, transfer.bytes)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpDownloadCompleted(payload),
        )
    })
}

fn sftp_upload_checked_response<F, Fut>(
    sftp_session_id: u64,
    local_path: *const c_char,
    remote_path: *const c_char,
    request_id: *const c_char,
    uploader: F,
) -> *mut c_char
where
    F: FnOnce(
        u64,
        String,
        String,
        Arc<AtomicBool>,
        Arc<dyn Fn(u64, Option<u64>) + Send + Sync>,
    ) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        if sftp_session_id == 0 {
            return Err(invalid_request("invalid_sftp_session_id", Some(request_id)));
        }
        let local_path = parse_local_upload_path(local_path, Some(request_id.clone()))?;
        let remote_path = parse_remote_path(remote_path, Some(request_id.clone()))?;
        let registration = SftpTransferRegistration::register(&request_id).map_err(|_| {
            invalid_request("duplicate_sftp_transfer_request", Some(request_id.clone()))
        })?;
        let progress_request_id = request_id.clone();
        let progress_last_emitted =
            Arc::new(Mutex::new(Instant::now() - SFTP_PROGRESS_MIN_INTERVAL));
        let progress = Arc::new(move |transferred: u64, total: Option<u64>| {
            let mut last_emitted = progress_last_emitted
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let is_complete = total.is_some_and(|total| transferred >= total);
            if transferred != 0
                && !is_complete
                && last_emitted.elapsed() < SFTP_PROGRESS_MIN_INTERVAL
            {
                return;
            }
            *last_emitted = Instant::now();
            emit_sftp_progress(&progress_request_id, transferred, total)
        });
        let transfer_json = ORBIT_RUNTIME
            .block_on(uploader(
                sftp_session_id,
                local_path,
                remote_path.clone(),
                Arc::clone(&registration.cancelled),
                progress,
            ))
            .map_err(|error| sftp_upload_error_payload(error, Some(request_id.clone())))?;
        let transfer: SftpTransferResult = serde_json::from_str(&transfer_json).map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::FfiInternalError,
                Some("sftp_upload_response_invalid"),
                Some(request_id.clone()),
                None,
            )
        })?;
        let payload = SftpUploadPayload::new(sftp_session_id, remote_path, transfer.bytes)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpUploadCompleted(payload),
        )
    })
}

fn sftp_mkdir_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    creator: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let remote_path = parse_mutation_remote_path(remote_path, Some(request_id.clone()))?;
        ORBIT_RUNTIME
            .block_on(creator(sftp_session_id, remote_path.clone()))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpMutationPayload::mkdir(sftp_session_id, remote_path)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

fn sftp_create_file_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    creator: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let remote_path = parse_mutation_remote_path(remote_path, Some(request_id.clone()))?;
        ORBIT_RUNTIME
            .block_on(creator(sftp_session_id, remote_path.clone()))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpMutationPayload::create_file(sftp_session_id, remote_path)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

#[allow(clippy::too_many_arguments)]
fn sftp_rename_checked_response<F, Fut>(
    sftp_session_id: u64,
    old_remote_path: *const c_char,
    new_remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    renamer: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, String, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let old_remote_path =
            parse_mutation_remote_path(old_remote_path, Some(request_id.clone()))?;
        let new_remote_path =
            parse_mutation_remote_path(new_remote_path, Some(request_id.clone()))?;
        if old_remote_path == new_remote_path {
            return Err(invalid_request("sftp_rename_paths_match", Some(request_id)));
        }
        let snapshot = parse_entry_snapshot(
            expected_size,
            expected_permissions_octal,
            expected_modified_at_unix,
            expected_is_directory,
            Some(request_id.clone()),
        )?;
        ORBIT_RUNTIME
            .block_on(renamer(
                sftp_session_id,
                old_remote_path.clone(),
                new_remote_path.clone(),
                snapshot,
            ))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload =
            SftpMutationPayload::rename(sftp_session_id, old_remote_path, new_remote_path)
                .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

#[allow(clippy::too_many_arguments)]
fn sftp_remove_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    remover: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let remote_path = parse_mutation_remote_path(remote_path, Some(request_id.clone()))?;
        let snapshot = parse_entry_snapshot(
            expected_size,
            expected_permissions_octal,
            expected_modified_at_unix,
            expected_is_directory,
            Some(request_id.clone()),
        )?;
        ORBIT_RUNTIME
            .block_on(remover(sftp_session_id, remote_path.clone(), snapshot))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpMutationPayload::remove(sftp_session_id, remote_path)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

#[allow(clippy::too_many_arguments)]
fn sftp_chmod_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    mode: u32,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    chmod: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, u32, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let remote_path = parse_mutation_remote_path(remote_path, Some(request_id.clone()))?;
        if mode > 0o7777 {
            return Err(invalid_request(
                "invalid_sftp_permissions",
                Some(request_id),
            ));
        }
        let snapshot = parse_entry_snapshot(
            expected_size,
            expected_permissions_octal,
            expected_modified_at_unix,
            expected_is_directory,
            Some(request_id.clone()),
        )?;
        ORBIT_RUNTIME
            .block_on(chmod(sftp_session_id, remote_path.clone(), mode, snapshot))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpMutationPayload::chmod(sftp_session_id, remote_path)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

#[allow(clippy::too_many_arguments)]
fn sftp_write_text_checked_response<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    content_ptr: *const u8,
    content_len: usize,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    writer: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, Vec<u8>, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    ffi_response(|| {
        let request_id = parse_request_id(request_id)?;
        ensure_sftp_session_id(sftp_session_id, &request_id)?;
        let remote_path = parse_mutation_remote_path(remote_path, Some(request_id.clone()))?;
        let content = parse_text_edit_content(content_ptr, content_len, Some(request_id.clone()))?;
        let snapshot = parse_entry_snapshot(
            expected_size,
            expected_permissions_octal,
            expected_modified_at_unix,
            expected_is_directory,
            Some(request_id.clone()),
        )?;
        ORBIT_RUNTIME
            .block_on(writer(
                sftp_session_id,
                remote_path.clone(),
                content,
                snapshot,
            ))
            .map_err(|error| sftp_mutation_error_payload(error, Some(request_id.clone())))?;
        let payload = SftpMutationPayload::write_text(sftp_session_id, remote_path)
            .map_err(|error| error.to_error_payload(Some(request_id.clone())))?;
        success_envelope(
            Some(request_id),
            HostKeyFfiResult::SftpMutationCompleted(payload),
        )
    })
}

fn parse_request_id(pointer: *const c_char) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_request_id", None));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // into Rust-owned memory before asynchronous work begins.
    let request_id = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("request_id_invalid_utf8"),
                None,
                None,
            )
        })?;
    if request_id.is_empty()
        || request_id.len() > MAX_REQUEST_ID_BYTES
        || !request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    {
        return Err(invalid_request("invalid_request_id", None));
    }
    Ok(request_id)
}

fn parse_remote_path(
    pointer: *const c_char,
    request_id: Option<String>,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_remote_path", request_id));
    }
    // SAFETY: The non-null C string is borrowed only for this call and copied
    // into Rust-owned memory before asynchronous work begins.
    let path = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("remote_path_invalid_utf8"),
                request_id.clone(),
                None,
            )
        })?;
    if path.len() > MAX_SFTP_PATH_BYTES || validate_sftp_path(&path).is_err() {
        return Err(invalid_request("invalid_remote_path", request_id));
    }
    Ok(path)
}

fn parse_mutation_remote_path(
    pointer: *const c_char,
    request_id: Option<String>,
) -> Result<String, HostKeyFfiErrorPayload> {
    let path = parse_remote_path(pointer, request_id.clone())?;
    if validate_sftp_mutation_path(&path).is_err() {
        return Err(invalid_request("invalid_sftp_mutation_path", request_id));
    }
    Ok(path)
}

fn ensure_sftp_session_id(
    sftp_session_id: u64,
    request_id: &str,
) -> Result<(), HostKeyFfiErrorPayload> {
    if sftp_session_id == 0 {
        return Err(invalid_request(
            "invalid_sftp_session_id",
            Some(request_id.to_string()),
        ));
    }
    Ok(())
}

fn parse_entry_snapshot(
    size: u64,
    permissions_octal: u32,
    modified_at_unix: u64,
    is_directory: i32,
    request_id: Option<String>,
) -> Result<SftpEntrySnapshot, HostKeyFfiErrorPayload> {
    if permissions_octal > 0o177_777 || !matches!(is_directory, 0 | 1) {
        return Err(invalid_request("invalid_sftp_entry_snapshot", request_id));
    }
    Ok(SftpEntrySnapshot {
        size,
        permissions_octal,
        modified_at_unix,
        is_directory: is_directory == 1,
    })
}

fn parse_text_edit_content(
    pointer: *const u8,
    length: usize,
    request_id: Option<String>,
) -> Result<Vec<u8>, HostKeyFfiErrorPayload> {
    if length > MAX_SFTP_TEXT_EDIT_BYTES || (length > 0 && pointer.is_null()) {
        return Err(invalid_request("invalid_sftp_text_content", request_id));
    }
    if length == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: The caller supplies `length` readable bytes. They are validated
    // and copied into Rust-owned storage before asynchronous work begins.
    let content = unsafe { std::slice::from_raw_parts(pointer, length) };
    if std::str::from_utf8(content).is_err() {
        return Err(invalid_request("invalid_sftp_text_content", request_id));
    }
    Ok(content.to_vec())
}

fn parse_local_download_path(
    pointer: *const c_char,
    request_id: Option<String>,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_local_path", request_id));
    }
    // SAFETY: The non-null C string is copied before asynchronous work begins.
    let path = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("local_path_invalid_utf8"),
                request_id.clone(),
                None,
            )
        })?;
    if path.is_empty()
        || path.len() > MAX_LOCAL_DOWNLOAD_PATH_BYTES
        || path.chars().any(char::is_control)
        || !Path::new(&path).is_absolute()
    {
        return Err(invalid_request("invalid_local_download_path", request_id));
    }
    Ok(path)
}

fn parse_local_upload_path(
    pointer: *const c_char,
    request_id: Option<String>,
) -> Result<String, HostKeyFfiErrorPayload> {
    if pointer.is_null() {
        return Err(invalid_request("null_local_path", request_id));
    }
    // SAFETY: The non-null C string is copied before asynchronous work begins.
    let path = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map(str::to_string)
        .map_err(|_| {
            HostKeyFfiErrorPayload::new(
                HostKeyFfiErrorCode::InvalidUtf8,
                Some("local_path_invalid_utf8"),
                request_id.clone(),
                None,
            )
        })?;
    if path.is_empty()
        || path.len() > MAX_LOCAL_DOWNLOAD_PATH_BYTES
        || path.chars().any(char::is_control)
        || !Path::new(&path).is_absolute()
    {
        return Err(invalid_request("invalid_local_upload_path", request_id));
    }
    Ok(path)
}

fn invalid_request(detail: &'static str, request_id: Option<String>) -> HostKeyFfiErrorPayload {
    HostKeyFfiErrorPayload::new(
        HostKeyFfiErrorCode::InvalidRequest,
        Some(detail),
        request_id,
        None,
    )
}

fn sftp_list_error_payload(
    error: OrbitCoreError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        OrbitCoreError::InvalidInput => invalid_request("invalid_remote_path", request_id),
        OrbitCoreError::LegacyNetworkDisabled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
            Some("legacy_session_not_allowed"),
            request_id,
            None,
        ),
        OrbitCoreError::SshFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SecurityGenerationMismatch,
            Some("sftp_generation_mismatch"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpTransferCancelled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpListFailed,
            Some("sftp_operation_cancelled"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpListFailed,
            Some("sftp_list_failed"),
            request_id,
            None,
        ),
        OrbitCoreError::Internal(_)
        | OrbitCoreError::EncryptFailed
        | OrbitCoreError::DecryptFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("sftp_list_internal"),
            request_id,
            None,
        ),
    }
}

fn sftp_read_error_payload(
    error: OrbitCoreError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        OrbitCoreError::InvalidInput => invalid_request("invalid_remote_path", request_id),
        OrbitCoreError::LegacyNetworkDisabled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
            Some("legacy_session_not_allowed"),
            request_id,
            None,
        ),
        OrbitCoreError::SshFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SecurityGenerationMismatch,
            Some("sftp_generation_mismatch"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpTransferCancelled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpReadFailed,
            Some("sftp_operation_cancelled"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpReadFailed,
            Some("sftp_read_failed"),
            request_id,
            None,
        ),
        OrbitCoreError::Internal(_)
        | OrbitCoreError::EncryptFailed
        | OrbitCoreError::DecryptFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("sftp_read_internal"),
            request_id,
            None,
        ),
    }
}

fn sftp_download_error_payload(
    error: OrbitCoreError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        OrbitCoreError::InvalidInput => {
            invalid_request("invalid_sftp_download_request", request_id)
        }
        OrbitCoreError::LegacyNetworkDisabled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
            Some("legacy_session_not_allowed"),
            request_id,
            None,
        ),
        OrbitCoreError::SshFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SecurityGenerationMismatch,
            Some("sftp_generation_mismatch"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpTransferCancelled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpDownloadFailed,
            Some("sftp_transfer_cancelled"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpDownloadFailed,
            Some("sftp_download_failed"),
            request_id,
            None,
        ),
        OrbitCoreError::Internal(_)
        | OrbitCoreError::EncryptFailed
        | OrbitCoreError::DecryptFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("sftp_download_internal"),
            request_id,
            None,
        ),
    }
}

fn sftp_upload_error_payload(
    error: OrbitCoreError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        OrbitCoreError::InvalidInput => invalid_request("invalid_sftp_upload_request", request_id),
        OrbitCoreError::LegacyNetworkDisabled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::LegacySessionNotAllowed,
            Some("legacy_session_not_allowed"),
            request_id,
            None,
        ),
        OrbitCoreError::SshFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SecurityGenerationMismatch,
            Some("sftp_generation_mismatch"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpTransferCancelled => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpUploadFailed,
            Some("sftp_transfer_cancelled"),
            request_id,
            None,
        ),
        OrbitCoreError::SftpFailed(_) => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpUploadFailed,
            Some("sftp_upload_failed"),
            request_id,
            None,
        ),
        OrbitCoreError::Internal(_)
        | OrbitCoreError::EncryptFailed
        | OrbitCoreError::DecryptFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::FfiInternalError,
            Some("sftp_upload_internal"),
            request_id,
            None,
        ),
    }
}

fn sftp_mutation_error_payload(
    error: SftpMutationError,
    request_id: Option<String>,
) -> HostKeyFfiErrorPayload {
    match error {
        SftpMutationError::InvalidRequest => {
            invalid_request("invalid_sftp_mutation_request", request_id)
        }
        SftpMutationError::SessionUnavailable => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SessionNotFound,
            Some("sftp_session_unavailable"),
            request_id,
            None,
        ),
        SftpMutationError::PermissionDenied => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpPermissionDenied,
            Some("permission_denied"),
            request_id,
            None,
        ),
        SftpMutationError::TargetExists => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpTargetExists,
            Some("sftp_target_exists"),
            request_id,
            None,
        ),
        SftpMutationError::EntryChanged => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpEntryChanged,
            Some("sftp_entry_changed"),
            request_id,
            None,
        ),
        SftpMutationError::BackendFailed => HostKeyFfiErrorPayload::new(
            HostKeyFfiErrorCode::SftpMutationFailed,
            Some("sftp_mutation_failed"),
            request_id,
            None,
        ),
    }
}

fn directory_list_payload(
    sftp_session_id: u64,
    path: String,
    list_json: &str,
) -> Result<SftpDirectoryListPayload, super::host_key_ffi_error::HostKeyFfiProtocolError> {
    let entries: Vec<LegacySftpListItem> = serde_json::from_str(list_json)
        .map_err(|_| super::host_key_ffi_error::HostKeyFfiProtocolError::InvalidJson)?;
    let entries = entries
        .into_iter()
        .map(|entry| {
            SftpDirectoryEntryPayload::new(
                entry.name,
                entry.size,
                entry.permissions,
                entry.permissions_octal,
                entry.modified_at_unix,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;
    SftpDirectoryListPayload::new(sftp_session_id, path, entries)
}

#[derive(Debug, Deserialize)]
struct LegacySftpListItem {
    name: String,
    size: u64,
    permissions: String,
    permissions_octal: u32,
    modified_at_unix: u64,
}

#[derive(Debug, Deserialize)]
struct SftpTransferResult {
    bytes: u64,
}

#[cfg(test)]
pub(crate) fn sftp_open_checked_response_for_tests<F, Fut>(
    base_session_id: u64,
    request_id: *const c_char,
    opener: F,
) -> *mut c_char
where
    F: FnOnce(u64) -> Fut,
    Fut: Future<Output = Result<SftpSessionId, CheckedChannelAccessError>>,
{
    sftp_open_checked_response(base_session_id, request_id, opener)
}

#[cfg(test)]
pub(crate) fn sftp_list_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    lister: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    sftp_list_checked_response(sftp_session_id, remote_path, request_id, lister)
}

#[cfg(test)]
pub(crate) fn sftp_read_text_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    reader: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    sftp_read_text_checked_response(sftp_session_id, remote_path, request_id, reader)
}

#[cfg(test)]
pub(crate) fn sftp_download_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    local_path: *const c_char,
    request_id: *const c_char,
    downloader: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    sftp_download_checked_response(
        sftp_session_id,
        remote_path,
        local_path,
        request_id,
        |session_id, remote_path, local_path, _, _| downloader(session_id, remote_path, local_path),
    )
}

#[cfg(test)]
pub(crate) fn sftp_upload_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    local_path: *const c_char,
    remote_path: *const c_char,
    request_id: *const c_char,
    uploader: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, String) -> Fut,
    Fut: Future<Output = Result<String, OrbitCoreError>>,
{
    sftp_upload_checked_response(
        sftp_session_id,
        local_path,
        remote_path,
        request_id,
        |session_id, local_path, remote_path, _, _| uploader(session_id, local_path, remote_path),
    )
}

#[cfg(test)]
pub(crate) fn sftp_mkdir_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    creator: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_mkdir_checked_response(sftp_session_id, remote_path, request_id, creator)
}

#[cfg(test)]
pub(crate) fn sftp_create_file_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    request_id: *const c_char,
    creator: F,
) -> *mut c_char
where
    F: FnOnce(u64, String) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_create_file_checked_response(sftp_session_id, remote_path, request_id, creator)
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn sftp_rename_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    old_remote_path: *const c_char,
    new_remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    renamer: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, String, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_rename_checked_response(
        sftp_session_id,
        old_remote_path,
        new_remote_path,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        renamer,
    )
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn sftp_remove_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    remover: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_remove_checked_response(
        sftp_session_id,
        remote_path,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        remover,
    )
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn sftp_chmod_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    mode: u32,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    chmod: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, u32, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_chmod_checked_response(
        sftp_session_id,
        remote_path,
        mode,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        chmod,
    )
}

#[cfg(test)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn sftp_write_text_checked_response_for_tests<F, Fut>(
    sftp_session_id: u64,
    remote_path: *const c_char,
    content_ptr: *const u8,
    content_len: usize,
    expected_size: u64,
    expected_permissions_octal: u32,
    expected_modified_at_unix: u64,
    expected_is_directory: i32,
    request_id: *const c_char,
    writer: F,
) -> *mut c_char
where
    F: FnOnce(u64, String, Vec<u8>, SftpEntrySnapshot) -> Fut,
    Fut: Future<Output = Result<(), SftpMutationError>>,
{
    sftp_write_text_checked_response(
        sftp_session_id,
        remote_path,
        content_ptr,
        content_len,
        expected_size,
        expected_permissions_octal,
        expected_modified_at_unix,
        expected_is_directory,
        request_id,
        writer,
    )
}
