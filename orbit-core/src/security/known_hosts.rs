use base64::{engine::general_purpose::STANDARD, Engine as _};
use hmac::{Hmac, Mac};
use sha1::Sha1;
use thiserror::Error;

use super::host_key::{
    decode_public_key_base64, fingerprint_sha256_from_base64, HostIdentity, HostKeyState,
};

type HmacSha1 = Hmac<Sha1>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnownHostMarker {
    None,
    Revoked,
    CertAuthority,
    Unsupported(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KnownHostPattern {
    Plain(String),
    Wildcard(String),
    Hashed {
        version: u8,
        salt: Vec<u8>,
        hash: Vec<u8>,
    },
    Negated(Box<KnownHostPattern>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostRecord {
    pub marker: KnownHostMarker,
    pub patterns: Vec<KnownHostPattern>,
    pub key_algorithm: String,
    pub public_key_base64: String,
    pub comment: Option<String>,
    pub source_line: String,
    pub line_number: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostsFile {
    pub records: Vec<KnownHostRecord>,
    pub unparsed_lines: Vec<UnparsedKnownHostsLine>,
    pub warnings: Vec<KnownHostsWarning>,
}

impl KnownHostsFile {
    pub fn parse(contents: &str) -> Self {
        let mut file = Self {
            records: Vec::new(),
            unparsed_lines: Vec::new(),
            warnings: Vec::new(),
        };

        for (index, source_line) in contents.lines().enumerate() {
            let line_number = index + 1;
            let trimmed = source_line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }

            match parse_record(source_line, line_number) {
                Ok(record) => file.records.push(record),
                Err(error) => {
                    file.warnings.push(KnownHostsWarning {
                        line_number,
                        error: error.clone(),
                    });
                    file.unparsed_lines.push(UnparsedKnownHostsLine {
                        line_number,
                        source_line: source_line.to_string(),
                    });
                }
            }
        }

        file
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnparsedKnownHostsLine {
    pub line_number: usize,
    pub source_line: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostsWarning {
    pub line_number: usize,
    pub error: KnownHostsError,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum KnownHostsError {
    #[error("known_hosts line does not contain host, algorithm, and key fields")]
    MissingFields,
    #[error("known_hosts marker is missing its host field")]
    MissingHostAfterMarker,
    #[error("known_hosts host pattern is invalid")]
    InvalidHostPattern,
    #[error("known_hosts key material is not valid base64")]
    InvalidKeyEncoding,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostsMatch {
    pub state: HostKeyState,
    pub fingerprint: Option<String>,
    pub matched_line: Option<usize>,
}

pub struct KnownHostsMatcher<'a> {
    file: &'a KnownHostsFile,
}

impl<'a> KnownHostsMatcher<'a> {
    pub fn new(file: &'a KnownHostsFile) -> Self {
        Self { file }
    }

    pub fn evaluate(
        &self,
        identity: &HostIdentity,
        key_algorithm: &str,
        public_key_base64: &str,
    ) -> KnownHostsMatch {
        evaluate_records(
            self.file.records.iter(),
            identity,
            key_algorithm,
            public_key_base64,
        )
    }
}

pub(crate) fn evaluate_records<'a>(
    records: impl IntoIterator<Item = &'a KnownHostRecord>,
    identity: &HostIdentity,
    key_algorithm: &str,
    public_key_base64: &str,
) -> KnownHostsMatch {
    let presented_key = match decode_public_key_base64(public_key_base64) {
        Ok(key) => key,
        Err(_) => {
            return KnownHostsMatch {
                state: HostKeyState::Invalid,
                fingerprint: None,
                matched_line: None,
            };
        }
    };
    let fingerprint = fingerprint_sha256_from_base64(public_key_base64).ok();
    let normalized_algorithm = key_algorithm.trim().to_ascii_lowercase();

    let mut trusted_line = None;
    let mut changed_line = None;
    let mut unsupported_line = None;

    for record in records {
        match patterns_match(&record.patterns, identity) {
            PatternSetMatch::NoMatch | PatternSetMatch::Excluded => continue,
            PatternSetMatch::Unsupported => {
                unsupported_line.get_or_insert(record.line_number);
                continue;
            }
            PatternSetMatch::Match => {}
        }

        let record_algorithm = record.key_algorithm.trim().to_ascii_lowercase();
        let record_key = match decode_public_key_base64(&record.public_key_base64) {
            Ok(key) => key,
            Err(_) => continue,
        };
        let same_algorithm = record_algorithm == normalized_algorithm;
        let same_key = record_key == presented_key;

        match &record.marker {
            KnownHostMarker::Revoked if same_algorithm && same_key => {
                return KnownHostsMatch {
                    state: HostKeyState::Revoked,
                    fingerprint,
                    matched_line: Some(record.line_number),
                };
            }
            KnownHostMarker::Revoked if same_algorithm => {
                changed_line.get_or_insert(record.line_number);
            }
            KnownHostMarker::CertAuthority | KnownHostMarker::Unsupported(_) => {
                unsupported_line.get_or_insert(record.line_number);
            }
            KnownHostMarker::None if same_algorithm && same_key => {
                trusted_line.get_or_insert(record.line_number);
            }
            KnownHostMarker::None if same_algorithm => {
                changed_line.get_or_insert(record.line_number);
            }
            _ => {}
        }
    }

    if let Some(line) = trusted_line {
        return KnownHostsMatch {
            state: HostKeyState::Trusted,
            fingerprint,
            matched_line: Some(line),
        };
    }
    if let Some(line) = changed_line {
        return KnownHostsMatch {
            state: HostKeyState::Changed,
            fingerprint,
            matched_line: Some(line),
        };
    }
    if let Some(line) = unsupported_line {
        return KnownHostsMatch {
            state: HostKeyState::Unsupported,
            fingerprint,
            matched_line: Some(line),
        };
    }

    KnownHostsMatch {
        state: HostKeyState::Unknown,
        fingerprint,
        matched_line: None,
    }
}

fn parse_record(source_line: &str, line_number: usize) -> Result<KnownHostRecord, KnownHostsError> {
    let mut fields = source_line.split_whitespace();
    let first = fields.next().ok_or(KnownHostsError::MissingFields)?;

    let (marker, hosts_field) = if first.starts_with('@') {
        let marker = match first {
            "@revoked" => KnownHostMarker::Revoked,
            "@cert-authority" => KnownHostMarker::CertAuthority,
            other => KnownHostMarker::Unsupported(other.to_string()),
        };
        let hosts = fields
            .next()
            .ok_or(KnownHostsError::MissingHostAfterMarker)?;
        (marker, hosts)
    } else {
        (KnownHostMarker::None, first)
    };

    let key_algorithm = fields.next().ok_or(KnownHostsError::MissingFields)?;
    let public_key_base64 = fields.next().ok_or(KnownHostsError::MissingFields)?;
    decode_public_key_base64(public_key_base64).map_err(|_| KnownHostsError::InvalidKeyEncoding)?;

    let patterns = hosts_field
        .split(',')
        .map(parse_pattern)
        .collect::<Result<Vec<_>, _>>()?;
    if patterns.is_empty() {
        return Err(KnownHostsError::InvalidHostPattern);
    }

    let comment = {
        let value = fields.collect::<Vec<_>>().join(" ");
        (!value.is_empty()).then_some(value)
    };

    Ok(KnownHostRecord {
        marker,
        patterns,
        key_algorithm: key_algorithm.to_string(),
        public_key_base64: public_key_base64.to_string(),
        comment,
        source_line: source_line.to_string(),
        line_number,
    })
}

fn parse_pattern(raw: &str) -> Result<KnownHostPattern, KnownHostsError> {
    if raw.is_empty() {
        return Err(KnownHostsError::InvalidHostPattern);
    }
    if let Some(inner) = raw.strip_prefix('!') {
        if inner.is_empty() {
            return Err(KnownHostsError::InvalidHostPattern);
        }
        return Ok(KnownHostPattern::Negated(Box::new(parse_pattern(inner)?)));
    }
    if raw.starts_with('|') {
        let fields = raw.split('|').collect::<Vec<_>>();
        if fields.len() != 4 || !fields[0].is_empty() {
            return Err(KnownHostsError::InvalidHostPattern);
        }
        let version = fields[1]
            .parse::<u8>()
            .map_err(|_| KnownHostsError::InvalidHostPattern)?;
        let salt = STANDARD
            .decode(fields[2])
            .map_err(|_| KnownHostsError::InvalidHostPattern)?;
        let hash = STANDARD
            .decode(fields[3])
            .map_err(|_| KnownHostsError::InvalidHostPattern)?;
        if salt.is_empty() || hash.is_empty() {
            return Err(KnownHostsError::InvalidHostPattern);
        }
        return Ok(KnownHostPattern::Hashed {
            version,
            salt,
            hash,
        });
    }
    if raw.contains('*') || raw.contains('?') {
        return Ok(KnownHostPattern::Wildcard(raw.to_ascii_lowercase()));
    }
    Ok(KnownHostPattern::Plain(raw.to_ascii_lowercase()))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PatternSetMatch {
    Match,
    NoMatch,
    Excluded,
    Unsupported,
}

fn patterns_match(patterns: &[KnownHostPattern], identity: &HostIdentity) -> PatternSetMatch {
    let mut positive_match = false;
    let mut unsupported = false;
    let lookup_tokens = identity_lookup_tokens(identity);

    for pattern in patterns {
        match pattern {
            KnownHostPattern::Negated(inner) => match pattern_matches_any(inner, &lookup_tokens) {
                PatternMatch::Match => return PatternSetMatch::Excluded,
                PatternMatch::Unsupported => unsupported = true,
                PatternMatch::NoMatch => {}
            },
            other => match pattern_matches_any(other, &lookup_tokens) {
                PatternMatch::Match => positive_match = true,
                PatternMatch::Unsupported => unsupported = true,
                PatternMatch::NoMatch => {}
            },
        }
    }

    if positive_match {
        PatternSetMatch::Match
    } else if unsupported {
        PatternSetMatch::Unsupported
    } else {
        PatternSetMatch::NoMatch
    }
}

pub(crate) fn pattern_matches_exact_identity(
    pattern: &KnownHostPattern,
    identity: &HostIdentity,
) -> bool {
    if matches!(
        pattern,
        KnownHostPattern::Wildcard(_) | KnownHostPattern::Negated(_)
    ) {
        return false;
    }
    identity_lookup_tokens(identity)
        .iter()
        .any(|token| pattern_matches(pattern, token) == PatternMatch::Match)
}

pub(crate) fn patterns_apply_to_identity(
    patterns: &[KnownHostPattern],
    identity: &HostIdentity,
) -> bool {
    patterns_match(patterns, identity) == PatternSetMatch::Match
}

fn identity_lookup_tokens(identity: &HostIdentity) -> Vec<String> {
    let mut lookup_tokens = vec![identity.lookup_token.clone()];
    if identity.port == 22 {
        lookup_tokens.push(format!("[{}]:22", identity.lookup_host));
    }
    lookup_tokens
}

fn pattern_matches_any(pattern: &KnownHostPattern, lookup_tokens: &[String]) -> PatternMatch {
    let mut unsupported = false;
    for token in lookup_tokens {
        match pattern_matches(pattern, token) {
            PatternMatch::Match => return PatternMatch::Match,
            PatternMatch::Unsupported => unsupported = true,
            PatternMatch::NoMatch => {}
        }
    }
    if unsupported {
        PatternMatch::Unsupported
    } else {
        PatternMatch::NoMatch
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PatternMatch {
    Match,
    NoMatch,
    Unsupported,
}

fn pattern_matches(pattern: &KnownHostPattern, lookup_token: &str) -> PatternMatch {
    let normalized_token = lookup_token.to_ascii_lowercase();
    match pattern {
        KnownHostPattern::Plain(value) => bool_match(value == &normalized_token),
        KnownHostPattern::Wildcard(value) => bool_match(wildcard_matches(value, &normalized_token)),
        KnownHostPattern::Hashed {
            version,
            salt,
            hash,
        } => {
            if *version != 1 {
                return PatternMatch::Unsupported;
            }
            let Ok(mut mac) = HmacSha1::new_from_slice(salt) else {
                return PatternMatch::Unsupported;
            };
            mac.update(lookup_token.as_bytes());
            bool_match(mac.verify_slice(hash).is_ok())
        }
        KnownHostPattern::Negated(inner) => pattern_matches(inner, lookup_token),
    }
}

fn bool_match(value: bool) -> PatternMatch {
    if value {
        PatternMatch::Match
    } else {
        PatternMatch::NoMatch
    }
}

fn wildcard_matches(pattern: &str, value: &str) -> bool {
    let pattern = pattern.as_bytes();
    let value = value.as_bytes();
    let (mut p, mut v) = (0usize, 0usize);
    let mut star = None;
    let mut checkpoint = 0usize;

    while v < value.len() {
        if p < pattern.len() && (pattern[p] == b'?' || pattern[p] == value[v]) {
            p += 1;
            v += 1;
        } else if p < pattern.len() && pattern[p] == b'*' {
            star = Some(p);
            p += 1;
            checkpoint = v;
        } else if let Some(star_index) = star {
            p = star_index + 1;
            checkpoint += 1;
            v = checkpoint;
        } else {
            return false;
        }
    }

    while p < pattern.len() && pattern[p] == b'*' {
        p += 1;
    }
    p == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;

    const KEY_A: &str = "AQIDBA==";
    const KEY_B: &str = "BQYHCA==";

    #[test]
    fn parser_supports_comments_blank_lines_and_standard_records() {
        let parsed = KnownHostsFile::parse(&format!(
            "\n# comment\nexample.com ssh-ed25519 {KEY_A} workstation\n192.0.2.10 ssh-ed25519 {KEY_A}\n2001:db8::1 ssh-ed25519 {KEY_A}\n[example.com]:2222 ssh-ed25519 {KEY_A}\n"
        ));
        assert_eq!(parsed.records.len(), 4);
        assert!(parsed.warnings.is_empty());
        assert_eq!(parsed.records[0].comment.as_deref(), Some("workstation"));
        assert_eq!(parsed.records[0].line_number, 3);
    }

    #[test]
    fn parser_supports_multiple_wildcard_and_negated_patterns() {
        let parsed = KnownHostsFile::parse(&format!(
            "*.example.com,!blocked.example.com,api.example.net ssh-ed25519 {KEY_A}"
        ));
        assert_eq!(parsed.records.len(), 1);
        assert_eq!(parsed.records[0].patterns.len(), 3);
        assert!(matches!(
            parsed.records[0].patterns[0],
            KnownHostPattern::Wildcard(_)
        ));
        assert!(matches!(
            parsed.records[0].patterns[1],
            KnownHostPattern::Negated(_)
        ));
    }

    #[test]
    fn parser_recognizes_revoked_and_certificate_authority_markers() {
        let parsed = KnownHostsFile::parse(&format!(
            "@revoked example.com ssh-ed25519 {KEY_A}\n@cert-authority *.example.net ssh-ed25519 {KEY_A}"
        ));
        assert_eq!(parsed.records.len(), 2);
        assert_eq!(parsed.records[0].marker, KnownHostMarker::Revoked);
        assert_eq!(parsed.records[1].marker, KnownHostMarker::CertAuthority);
    }

    #[test]
    fn parser_recognizes_hashed_hosts() {
        let hashed = hashed_pattern("example.com", b"01234567890123456789");
        let parsed = KnownHostsFile::parse(&format!("{hashed} ssh-ed25519 {KEY_A}"));
        assert_eq!(parsed.records.len(), 1);
        assert!(matches!(
            parsed.records[0].patterns[0],
            KnownHostPattern::Hashed { version: 1, .. }
        ));
    }

    #[test]
    fn parser_preserves_malformed_lines_without_discarding_valid_records() {
        let parsed = KnownHostsFile::parse(&format!(
            "malformed\nexample.com ssh-ed25519 {KEY_A}\nbad.example ssh-ed25519 %%%"
        ));
        assert_eq!(parsed.records.len(), 1);
        assert_eq!(parsed.warnings.len(), 2);
        assert_eq!(parsed.unparsed_lines.len(), 2);
        assert_eq!(parsed.unparsed_lines[0].source_line, "malformed");
    }

    #[test]
    fn matcher_reports_unknown_trusted_and_changed() {
        let identity = HostIdentity::parse("example.com", 22).unwrap();
        let unknown = KnownHostsMatcher::new(&KnownHostsFile::parse("")).evaluate(
            &identity,
            "ssh-ed25519",
            KEY_A,
        );
        assert_eq!(unknown.state, HostKeyState::Unknown);

        let file = KnownHostsFile::parse(&format!("example.com ssh-ed25519 {KEY_A}"));
        let matcher = KnownHostsMatcher::new(&file);
        assert_eq!(
            matcher.evaluate(&identity, "ssh-ed25519", KEY_A).state,
            HostKeyState::Trusted
        );
        assert_eq!(
            matcher.evaluate(&identity, "ssh-ed25519", KEY_B).state,
            HostKeyState::Changed
        );
    }

    #[test]
    fn revoked_key_takes_precedence_over_trusted_key() {
        let identity = HostIdentity::parse("example.com", 22).unwrap();
        let file = KnownHostsFile::parse(&format!(
            "example.com ssh-ed25519 {KEY_A}\n@revoked example.com ssh-ed25519 {KEY_A}"
        ));
        let result = KnownHostsMatcher::new(&file).evaluate(&identity, "ssh-ed25519", KEY_A);
        assert_eq!(result.state, HostKeyState::Revoked);
        assert_eq!(result.matched_line, Some(2));
    }

    #[test]
    fn different_algorithm_is_not_implicitly_trusted() {
        let identity = HostIdentity::parse("example.com", 22).unwrap();
        let file = KnownHostsFile::parse(&format!("example.com ssh-rsa {KEY_A}"));
        let result = KnownHostsMatcher::new(&file).evaluate(&identity, "ssh-ed25519", KEY_A);
        assert_eq!(result.state, HostKeyState::Unknown);
    }

    #[test]
    fn default_and_custom_ports_do_not_cross_match() {
        let file = KnownHostsFile::parse(&format!(
            "example.com ssh-ed25519 {KEY_A}\n[example.com]:2222 ssh-ed25519 {KEY_B}"
        ));
        let matcher = KnownHostsMatcher::new(&file);
        let default = HostIdentity::parse("example.com", 22).unwrap();
        let custom = HostIdentity::parse("example.com", 2222).unwrap();
        assert_eq!(
            matcher.evaluate(&default, "ssh-ed25519", KEY_A).state,
            HostKeyState::Trusted
        );
        assert_eq!(
            matcher.evaluate(&custom, "ssh-ed25519", KEY_B).state,
            HostKeyState::Trusted
        );
        assert_eq!(
            matcher.evaluate(&custom, "ssh-ed25519", KEY_A).state,
            HostKeyState::Changed
        );
    }

    #[test]
    fn explicit_port_22_record_matches_default_port_identity() {
        let file = KnownHostsFile::parse(&format!(
            "[example.com]:22 ssh-ed25519 {KEY_A}\n[2001:db8::1]:22 ssh-ed25519 {KEY_B}"
        ));
        let matcher = KnownHostsMatcher::new(&file);
        let dns = HostIdentity::parse("example.com", 22).unwrap();
        let ipv6 = HostIdentity::parse("2001:db8::1", 22).unwrap();
        assert_eq!(
            matcher.evaluate(&dns, "ssh-ed25519", KEY_A).state,
            HostKeyState::Trusted
        );
        assert_eq!(
            matcher.evaluate(&ipv6, "ssh-ed25519", KEY_B).state,
            HostKeyState::Trusted
        );
    }

    #[test]
    fn ip_and_dns_records_do_not_cross_match() {
        let file = KnownHostsFile::parse(&format!("example.com ssh-ed25519 {KEY_A}"));
        let ip = HostIdentity::parse("192.0.2.10", 22).unwrap();
        let result = KnownHostsMatcher::new(&file).evaluate(&ip, "ssh-ed25519", KEY_A);
        assert_eq!(result.state, HostKeyState::Unknown);
    }

    #[test]
    fn certificate_authority_record_is_not_a_plain_trust_record() {
        let identity = HostIdentity::parse("api.example.com", 22).unwrap();
        let file = KnownHostsFile::parse(&format!(
            "@cert-authority *.example.com ssh-ed25519 {KEY_A}"
        ));
        let result = KnownHostsMatcher::new(&file).evaluate(&identity, "ssh-ed25519", KEY_A);
        assert_eq!(result.state, HostKeyState::Unsupported);
    }

    #[test]
    fn hashed_host_matches_open_ssh_hmac_sha1_format() {
        let token = "[example.com]:2222";
        let pattern = hashed_pattern(token, b"01234567890123456789");
        let file = KnownHostsFile::parse(&format!("{pattern} ssh-ed25519 {KEY_A}"));
        let identity = HostIdentity::parse("example.com", 2222).unwrap();
        let result = KnownHostsMatcher::new(&file).evaluate(&identity, "ssh-ed25519", KEY_A);
        assert_eq!(result.state, HostKeyState::Trusted);
    }

    #[test]
    fn wildcard_and_negation_follow_host_pattern_rules() {
        let file = KnownHostsFile::parse(&format!(
            "*.example.com,!blocked.example.com ssh-ed25519 {KEY_A}"
        ));
        let matcher = KnownHostsMatcher::new(&file);
        let allowed = HostIdentity::parse("api.example.com", 22).unwrap();
        let blocked = HostIdentity::parse("blocked.example.com", 22).unwrap();
        assert_eq!(
            matcher.evaluate(&allowed, "ssh-ed25519", KEY_A).state,
            HostKeyState::Trusted
        );
        assert_eq!(
            matcher.evaluate(&blocked, "ssh-ed25519", KEY_A).state,
            HostKeyState::Unknown
        );
    }

    #[test]
    fn invalid_presented_key_returns_invalid_without_key_material() {
        let identity = HostIdentity::parse("example.com", 22).unwrap();
        let file = KnownHostsFile::parse(&format!("example.com ssh-ed25519 {KEY_A}"));
        let result = KnownHostsMatcher::new(&file).evaluate(
            &identity,
            "ssh-ed25519",
            "%%%private-key-material%%%",
        );
        assert_eq!(result.state, HostKeyState::Invalid);
        assert!(result.fingerprint.is_none());
    }

    fn hashed_pattern(token: &str, salt: &[u8]) -> String {
        let mut mac = HmacSha1::new_from_slice(salt).unwrap();
        mac.update(token.as_bytes());
        let hash = mac.finalize().into_bytes();
        format!("|1|{}|{}", STANDARD.encode(salt), STANDARD.encode(hash))
    }
}
