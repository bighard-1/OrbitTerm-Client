use std::collections::HashMap;
use std::io;
use std::path::Path;

use base64::{engine::general_purpose::STANDARD, Engine as _};
use thiserror::Error;

use super::host_key::{decode_public_key_base64, HostIdentity, HostKeyState};
use super::known_hosts::{
    evaluate_records, pattern_matches_exact_identity, patterns_apply_to_identity, KnownHostMarker,
    KnownHostPattern, KnownHostRecord, KnownHostsFile, KnownHostsMatch, KnownHostsWarning,
};
use super::known_hosts_format::render_record;
use super::known_hosts_persistence::{atomic_write, read_file};

/// A one-megabyte default comfortably covers thousands of host keys while
/// preventing an accidentally or maliciously huge file from exhausting memory.
pub const DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE: usize = 1024 * 1024;
const MAX_COMMENT_CHARS: usize = 512;
const MAX_ALGORITHM_BYTES: usize = 128;
pub(crate) const MAX_PUBLIC_KEY_BASE64_BYTES: usize = 64 * 1024;

#[derive(Debug, Clone)]
pub struct KnownHostsStore {
    lines: Vec<StoredLine>,
    warnings: Vec<KnownHostsStoreWarning>,
    max_file_size: usize,
    trailing_newline: bool,
}

impl KnownHostsStore {
    pub fn empty() -> Self {
        Self::empty_with_limit(DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE)
    }

    pub fn empty_with_limit(max_file_size: usize) -> Self {
        Self {
            lines: Vec::new(),
            warnings: Vec::new(),
            max_file_size: max_file_size.max(1),
            trailing_newline: false,
        }
    }

    pub fn from_text(contents: &str) -> Result<Self, KnownHostsStoreError> {
        Self::from_text_with_limit(contents, DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE)
    }

    pub fn from_text_with_limit(
        contents: &str,
        max_file_size: usize,
    ) -> Result<Self, KnownHostsStoreError> {
        let limit = max_file_size.max(1);
        if contents.len() > limit {
            return Err(KnownHostsStoreError::FileTooLarge { max_bytes: limit });
        }

        let parsed = KnownHostsFile::parse(contents);
        let mut records_by_line = parsed
            .records
            .into_iter()
            .map(|record| (record.line_number, record))
            .collect::<HashMap<_, _>>();
        let warnings = parsed
            .warnings
            .into_iter()
            .map(KnownHostsStoreWarning::Parser)
            .collect();

        let lines = contents
            .split_terminator('\n')
            .enumerate()
            .map(|(index, line)| {
                let line_number = index + 1;
                if let Some(record) = records_by_line.remove(&line_number) {
                    StoredLine::Record {
                        record,
                        dirty: false,
                    }
                } else {
                    StoredLine::Preserved(line.strip_suffix('\r').unwrap_or(line).to_string())
                }
            })
            .collect();

        Ok(Self {
            lines,
            warnings,
            max_file_size: limit,
            trailing_newline: contents.ends_with('\n'),
        })
    }

    pub fn load(path: impl AsRef<Path>) -> Result<Self, KnownHostsStoreError> {
        Self::load_with_limit(path, DEFAULT_MAX_KNOWN_HOSTS_FILE_SIZE)
    }

    pub fn load_with_limit(
        path: impl AsRef<Path>,
        max_file_size: usize,
    ) -> Result<Self, KnownHostsStoreError> {
        let limit = max_file_size.max(1);
        let Some(loaded) = read_file(path.as_ref(), limit)? else {
            return Ok(Self::empty_with_limit(limit));
        };
        let mut store = Self::from_text_with_limit(&loaded.contents, limit)?;
        if let Some(mode) = loaded.insecure_mode {
            store
                .warnings
                .push(KnownHostsStoreWarning::InsecurePermissions { mode });
        }
        Ok(store)
    }

    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), KnownHostsStoreError> {
        let path = path.as_ref();
        let contents = self.to_text();
        if contents.len() > self.max_file_size {
            return Err(KnownHostsStoreError::FileTooLarge {
                max_bytes: self.max_file_size,
            });
        }
        atomic_write(path, contents.as_bytes())
    }

    pub fn to_text(&self) -> String {
        let mut output = self
            .lines
            .iter()
            .map(StoredLine::render)
            .collect::<Vec<_>>()
            .join("\n");
        if self.trailing_newline && !self.lines.is_empty() {
            output.push('\n');
        }
        output
    }

    pub fn warnings(&self) -> &[KnownHostsStoreWarning] {
        &self.warnings
    }

    pub fn records(&self) -> impl Iterator<Item = &KnownHostRecord> {
        self.lines.iter().filter_map(StoredLine::record)
    }

    pub fn query(
        &self,
        identity: &HostIdentity,
        key_algorithm: &str,
        public_key_base64: &str,
    ) -> KnownHostsMatch {
        evaluate_records(self.records(), identity, key_algorithm, public_key_base64)
    }

    pub fn add_trusted_key(
        &mut self,
        identity: &HostIdentity,
        key_algorithm: &str,
        public_key_base64: &str,
        comment: Option<&str>,
    ) -> Result<AddTrustedKeyOutcome, KnownHostsStoreError> {
        let algorithm = normalize_algorithm(key_algorithm)?;
        let canonical_key = canonical_public_key(public_key_base64)?;
        let sanitized_comment = sanitize_comment(comment)?;

        match self.query(identity, &algorithm, &canonical_key).state {
            HostKeyState::Trusted => return Ok(AddTrustedKeyOutcome::AlreadyTrusted),
            HostKeyState::Changed => return Err(KnownHostsStoreError::ChangedKeyConflict),
            HostKeyState::Revoked => return Err(KnownHostsStoreError::RevokedConflict),
            HostKeyState::Unsupported => return Err(KnownHostsStoreError::UnsupportedMarker),
            HostKeyState::Invalid => return Err(KnownHostsStoreError::InvalidPublicKey),
            HostKeyState::Unknown | HostKeyState::Error => {}
        }

        self.append_record(new_record(
            identity,
            KnownHostMarker::None,
            algorithm,
            canonical_key,
            sanitized_comment,
        ));
        Ok(AddTrustedKeyOutcome::Added)
    }

    pub fn mark_revoked(
        &mut self,
        identity: &HostIdentity,
        key_algorithm: &str,
        public_key_base64: &str,
        comment: Option<&str>,
    ) -> Result<AddRevokedKeyOutcome, KnownHostsStoreError> {
        let algorithm = normalize_algorithm(key_algorithm)?;
        let canonical_key = canonical_public_key(public_key_base64)?;
        let sanitized_comment = sanitize_comment(comment)?;

        if self.query(identity, &algorithm, &canonical_key).state == HostKeyState::Revoked {
            return Ok(AddRevokedKeyOutcome::AlreadyRevoked);
        }

        self.append_record(new_record(
            identity,
            KnownHostMarker::Revoked,
            algorithm,
            canonical_key,
            sanitized_comment,
        ));
        Ok(AddRevokedKeyOutcome::Added)
    }

    pub fn remove_trusted_key(
        &mut self,
        identity: &HostIdentity,
        key_algorithm: &str,
    ) -> Result<usize, KnownHostsStoreError> {
        let algorithm = normalize_algorithm(key_algorithm)?;
        Ok(self.remove_matching_patterns(identity, Some(&algorithm), MarkerFilter::Trusted))
    }

    pub fn remove_all_trusted(&mut self, identity: &HostIdentity) -> usize {
        self.remove_matching_patterns(identity, None, MarkerFilter::Trusted)
    }

    pub fn remove_revoked(
        &mut self,
        identity: &HostIdentity,
        key_algorithm: &str,
    ) -> Result<usize, KnownHostsStoreError> {
        let algorithm = normalize_algorithm(key_algorithm)?;
        Ok(self.remove_matching_patterns(identity, Some(&algorithm), MarkerFilter::Revoked))
    }

    /// Replaces a trusted key only when the caller supplies the expected old
    /// key. A2 must call this API only after explicit user confirmation.
    pub fn replace_trusted_key(
        &mut self,
        identity: &HostIdentity,
        key_algorithm: &str,
        expected_old_key_base64: &str,
        new_key_base64: &str,
        comment: Option<&str>,
    ) -> Result<ReplaceTrustedKeyOutcome, KnownHostsStoreError> {
        let algorithm = normalize_algorithm(key_algorithm)?;
        let expected_old_key = canonical_public_key(expected_old_key_base64)?;
        let new_key = canonical_public_key(new_key_base64)?;
        let sanitized_comment = sanitize_comment(comment)?;

        if self.query(identity, &algorithm, &new_key).state == HostKeyState::Revoked {
            return Err(KnownHostsStoreError::RevokedConflict);
        }

        let expected_old_bytes = decode_public_key_base64(&expected_old_key)
            .map_err(|_| KnownHostsStoreError::InvalidPublicKey)?;
        let mut matched_patterns = None;

        for line in &mut self.lines {
            let StoredLine::Record { record, dirty } = line else {
                continue;
            };
            if record.marker != KnownHostMarker::None
                || !record.key_algorithm.eq_ignore_ascii_case(&algorithm)
            {
                continue;
            }
            let Ok(record_key) = decode_public_key_base64(&record.public_key_base64) else {
                continue;
            };
            if record_key != expected_old_bytes {
                continue;
            }

            let selected = record
                .patterns
                .iter()
                .filter(|pattern| pattern_matches_exact_identity(pattern, identity))
                .cloned()
                .collect::<Vec<_>>();
            if selected.is_empty() {
                continue;
            }
            let remaining_patterns = record
                .patterns
                .iter()
                .filter(|pattern| !pattern_matches_exact_identity(pattern, identity))
                .cloned()
                .collect::<Vec<_>>();
            if patterns_apply_to_identity(&remaining_patterns, identity) {
                return Err(KnownHostsStoreError::AmbiguousHostPattern);
            }

            if selected.len() == record.patterns.len() {
                record.public_key_base64 = new_key.clone();
                record.comment = sanitized_comment.clone();
                *dirty = true;
            } else {
                record
                    .patterns
                    .retain(|pattern| !pattern_matches_exact_identity(pattern, identity));
                *dirty = true;
                matched_patterns = Some(selected);
            }
            self.reindex_records();
            if let Some(patterns) = matched_patterns {
                self.append_record(KnownHostRecord {
                    marker: KnownHostMarker::None,
                    patterns,
                    key_algorithm: algorithm,
                    public_key_base64: new_key,
                    comment: sanitized_comment,
                    source_line: String::new(),
                    line_number: 0,
                });
            }
            return Ok(ReplaceTrustedKeyOutcome::Updated);
        }

        if self.query(identity, &algorithm, &new_key).state == HostKeyState::Trusted {
            Ok(ReplaceTrustedKeyOutcome::AlreadyTrusted)
        } else {
            Err(KnownHostsStoreError::TrustedRecordNotFound)
        }
    }

    fn append_record(&mut self, mut record: KnownHostRecord) {
        record.line_number = self.lines.len() + 1;
        record.source_line = render_record(&record);
        self.lines.push(StoredLine::Record {
            record,
            dirty: true,
        });
        self.trailing_newline = true;
        self.reindex_records();
    }

    fn remove_matching_patterns(
        &mut self,
        identity: &HostIdentity,
        algorithm: Option<&str>,
        marker_filter: MarkerFilter,
    ) -> usize {
        let mut removed = 0;
        let mut index = 0;

        while index < self.lines.len() {
            let mut remove_line = false;
            if let StoredLine::Record { record, dirty } = &mut self.lines[index] {
                let marker_matches = match marker_filter {
                    MarkerFilter::Trusted => record.marker == KnownHostMarker::None,
                    MarkerFilter::Revoked => record.marker == KnownHostMarker::Revoked,
                };
                let algorithm_matches = algorithm
                    .map(|value| record.key_algorithm.eq_ignore_ascii_case(value))
                    .unwrap_or(true);

                if marker_matches && algorithm_matches {
                    let before = record.patterns.len();
                    record
                        .patterns
                        .retain(|pattern| !pattern_matches_exact_identity(pattern, identity));
                    let removed_from_record = before - record.patterns.len();
                    if removed_from_record > 0 {
                        removed += removed_from_record;
                        *dirty = true;
                        remove_line = record.patterns.is_empty();
                    }
                }
            }

            if remove_line {
                self.lines.remove(index);
            } else {
                index += 1;
            }
        }

        self.reindex_records();
        removed
    }

    fn reindex_records(&mut self) {
        for (index, line) in self.lines.iter_mut().enumerate() {
            if let StoredLine::Record { record, .. } = line {
                record.line_number = index + 1;
            }
        }
    }
}

impl Default for KnownHostsStore {
    fn default() -> Self {
        Self::empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddTrustedKeyOutcome {
    Added,
    AlreadyTrusted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AddRevokedKeyOutcome {
    Added,
    AlreadyRevoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplaceTrustedKeyOutcome {
    Updated,
    AlreadyTrusted,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnownHostsStoreWarning {
    Parser(KnownHostsWarning),
    InsecurePermissions { mode: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum KnownHostsStoreError {
    #[error("known_hosts path is invalid")]
    InvalidPath,
    #[error("known_hosts file exceeds the {max_bytes}-byte limit")]
    FileTooLarge { max_bytes: usize },
    #[error("known_hosts file could not be read ({kind:?})")]
    ReadFailed { kind: io::ErrorKind },
    #[error("known_hosts file is not valid UTF-8")]
    InvalidUtf8,
    #[error("known_hosts temporary file could not be created ({kind:?})")]
    TemporaryFileCreateFailed { kind: io::ErrorKind },
    #[error("known_hosts temporary file could not be written ({kind:?})")]
    WriteFailed { kind: io::ErrorKind },
    #[error("known_hosts temporary file could not be flushed ({kind:?})")]
    FlushFailed { kind: io::ErrorKind },
    #[error("known_hosts temporary file could not be synchronized ({kind:?})")]
    SyncFailed { kind: io::ErrorKind },
    #[error("known_hosts file could not be atomically replaced ({kind:?})")]
    AtomicReplaceFailed { kind: io::ErrorKind },
    #[error("known_hosts permission update failed ({kind:?})")]
    PermissionFailed { kind: io::ErrorKind },
    #[error("host public key is invalid")]
    InvalidPublicKey,
    #[error("host key algorithm is invalid")]
    InvalidAlgorithm,
    #[error("host key comment is invalid")]
    InvalidComment,
    #[error("a different key already exists for this host and algorithm")]
    ChangedKeyConflict,
    #[error("the presented host key is revoked")]
    RevokedConflict,
    #[error("an applicable unsupported known_hosts marker prevents automatic trust")]
    UnsupportedMarker,
    #[error("the expected trusted host key record was not found")]
    TrustedRecordNotFound,
    #[error("a broader host pattern still applies to this identity")]
    AmbiguousHostPattern,
}

#[derive(Debug, Clone)]
enum StoredLine {
    Record {
        record: KnownHostRecord,
        dirty: bool,
    },
    Preserved(String),
}

impl StoredLine {
    fn render(&self) -> String {
        match self {
            Self::Record { record, dirty } if !dirty => record.source_line.clone(),
            Self::Record { record, .. } => render_record(record),
            Self::Preserved(line) => line.clone(),
        }
    }

    fn record(&self) -> Option<&KnownHostRecord> {
        match self {
            Self::Record { record, .. } => Some(record),
            Self::Preserved(_) => None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum MarkerFilter {
    Trusted,
    Revoked,
}

fn new_record(
    identity: &HostIdentity,
    marker: KnownHostMarker,
    key_algorithm: String,
    public_key_base64: String,
    comment: Option<String>,
) -> KnownHostRecord {
    KnownHostRecord {
        marker,
        patterns: vec![KnownHostPattern::Plain(identity.lookup_token.clone())],
        key_algorithm,
        public_key_base64,
        comment,
        source_line: String::new(),
        line_number: 0,
    }
}

pub(crate) fn normalize_algorithm(value: &str) -> Result<String, KnownHostsStoreError> {
    let algorithm = value.trim();
    if algorithm.is_empty()
        || algorithm.len() > MAX_ALGORITHM_BYTES
        || !algorithm.is_ascii()
        || !algorithm.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'@' | b'+')
        })
    {
        return Err(KnownHostsStoreError::InvalidAlgorithm);
    }
    Ok(algorithm.to_ascii_lowercase())
}

pub(crate) fn canonical_public_key(value: &str) -> Result<String, KnownHostsStoreError> {
    if value.len() > MAX_PUBLIC_KEY_BASE64_BYTES {
        return Err(KnownHostsStoreError::InvalidPublicKey);
    }
    let bytes =
        decode_public_key_base64(value).map_err(|_| KnownHostsStoreError::InvalidPublicKey)?;
    Ok(STANDARD.encode(bytes))
}

fn sanitize_comment(comment: Option<&str>) -> Result<Option<String>, KnownHostsStoreError> {
    let Some(comment) = comment else {
        return Ok(None);
    };

    let cleaned = comment
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    if cleaned.chars().count() > MAX_COMMENT_CHARS {
        return Err(KnownHostsStoreError::InvalidComment);
    }
    Ok((!cleaned.is_empty()).then_some(cleaned))
}
