use std::net::IpAddr;

use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD},
    Engine as _,
};
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Normalized identity used for Known Hosts lookup.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct HostIdentity {
    pub original_host: String,
    pub normalized_host: String,
    pub port: u16,
    pub lookup_host: String,
    pub lookup_token: String,
}

impl HostIdentity {
    /// Parses a hostname, IP, or host-with-port target.
    ///
    /// An explicit port in `target` takes precedence over `default_port`, which
    /// mirrors the existing OrbitTerm connection target behavior.
    pub fn parse(target: &str, default_port: u16) -> Result<Self, HostIdentityError> {
        if default_port == 0 {
            return Err(HostIdentityError::InvalidPort);
        }

        let original_host = target.trim();
        if original_host.is_empty() {
            return Err(HostIdentityError::EmptyHost);
        }

        let (host, port) = split_target(original_host, default_port)?;
        let normalized_host = normalize_host(&host)?;
        let lookup_token = if port == 22 {
            normalized_host.clone()
        } else {
            format!("[{normalized_host}]:{port}")
        };

        Ok(Self {
            original_host: original_host.to_string(),
            lookup_host: normalized_host.clone(),
            normalized_host,
            port,
            lookup_token,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostKeyState {
    Unknown,
    Trusted,
    Changed,
    Revoked,
    Unsupported,
    Invalid,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HostIdentityError {
    #[error("host is empty")]
    EmptyHost,
    #[error("host target format is invalid")]
    InvalidFormat,
    #[error("port is invalid")]
    InvalidPort,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum FingerprintError {
    #[error("public key is not valid base64")]
    InvalidBase64,
}

/// Formats a public-key blob using the OpenSSH SHA-256 fingerprint style.
pub fn fingerprint_sha256(public_key_blob: &[u8]) -> String {
    let digest = Sha256::digest(public_key_blob);
    format!("SHA256:{}", STANDARD_NO_PAD.encode(digest))
}

/// Decodes a Base64 public-key blob and formats its SHA-256 fingerprint.
pub fn fingerprint_sha256_from_base64(public_key_base64: &str) -> Result<String, FingerprintError> {
    let bytes = decode_public_key_base64(public_key_base64)?;
    Ok(fingerprint_sha256(&bytes))
}

pub(crate) fn decode_public_key_base64(
    public_key_base64: &str,
) -> Result<Vec<u8>, FingerprintError> {
    let encoded = public_key_base64.trim();
    STANDARD
        .decode(encoded)
        .or_else(|_| STANDARD_NO_PAD.decode(encoded))
        .map_err(|_| FingerprintError::InvalidBase64)
}

fn split_target(target: &str, default_port: u16) -> Result<(String, u16), HostIdentityError> {
    if let Some(rest) = target.strip_prefix('[') {
        let closing = rest.find(']').ok_or(HostIdentityError::InvalidFormat)?;
        let host = &rest[..closing];
        if host.is_empty() {
            return Err(HostIdentityError::EmptyHost);
        }

        let suffix = &rest[closing + 1..];
        let port = if suffix.is_empty() {
            default_port
        } else {
            let raw_port = suffix
                .strip_prefix(':')
                .ok_or(HostIdentityError::InvalidFormat)?;
            parse_port(raw_port)?
        };
        return Ok((host.to_string(), port));
    }

    if target.parse::<IpAddr>().is_ok() {
        return Ok((target.to_string(), default_port));
    }

    if target.matches(':').count() == 1 {
        let (host, raw_port) = target
            .rsplit_once(':')
            .ok_or(HostIdentityError::InvalidFormat)?;
        if host.is_empty() || raw_port.is_empty() {
            return Err(HostIdentityError::InvalidFormat);
        }
        return Ok((host.to_string(), parse_port(raw_port)?));
    }

    if target.contains(':') {
        return Err(HostIdentityError::InvalidFormat);
    }

    Ok((target.to_string(), default_port))
}

fn parse_port(raw_port: &str) -> Result<u16, HostIdentityError> {
    let port = raw_port
        .parse::<u16>()
        .map_err(|_| HostIdentityError::InvalidPort)?;
    if port == 0 {
        return Err(HostIdentityError::InvalidPort);
    }
    Ok(port)
}

fn normalize_host(host: &str) -> Result<String, HostIdentityError> {
    let trimmed = host.trim();
    if trimmed.is_empty() {
        return Err(HostIdentityError::EmptyHost);
    }

    if let Ok(ip) = trimmed.parse::<IpAddr>() {
        return Ok(ip.to_string());
    }

    let normalized = trimmed.trim_end_matches('.').to_ascii_lowercase();
    if normalized.is_empty()
        || normalized
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
        || normalized.contains(['[', ']', ',', '|', '!', '*', '?', '/', '\\', '#'])
    {
        return Err(HostIdentityError::InvalidFormat);
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_hostname_and_default_port() {
        let identity = HostIdentity::parse("Example.COM.:22", 22).unwrap();
        assert_eq!(identity.normalized_host, "example.com");
        assert_eq!(identity.port, 22);
        assert_eq!(identity.lookup_token, "example.com");
    }

    #[test]
    fn separates_non_default_hostname_port() {
        let identity = HostIdentity::parse("example.com:2222", 22).unwrap();
        assert_eq!(identity.lookup_token, "[example.com]:2222");
    }

    #[test]
    fn handles_ipv4_default_and_custom_ports() {
        let default = HostIdentity::parse("192.168.1.10", 22).unwrap();
        let custom = HostIdentity::parse("192.168.1.10:2222", 22).unwrap();
        assert_eq!(default.lookup_token, "192.168.1.10");
        assert_eq!(custom.lookup_token, "[192.168.1.10]:2222");
    }

    #[test]
    fn canonicalizes_bare_ipv6() {
        let identity = HostIdentity::parse("2001:0db8:0:0:0:0:0:1", 22).unwrap();
        assert_eq!(identity.lookup_host, "2001:db8::1");
        assert_eq!(identity.lookup_token, "2001:db8::1");
    }

    #[test]
    fn handles_bracketed_ipv6_ports() {
        let default = HostIdentity::parse("[2001:db8::1]:22", 2222).unwrap();
        let custom = HostIdentity::parse("[2001:db8::1]:2222", 22).unwrap();
        assert_eq!(default.lookup_token, "2001:db8::1");
        assert_eq!(custom.lookup_token, "[2001:db8::1]:2222");
    }

    #[test]
    fn keeps_dns_and_ip_identities_distinct() {
        let dns = HostIdentity::parse("server.example", 22).unwrap();
        let ip = HostIdentity::parse("203.0.113.7", 22).unwrap();
        assert_ne!(dns.lookup_token, ip.lookup_token);
    }

    #[test]
    fn rejects_invalid_targets() {
        assert_eq!(
            HostIdentity::parse("", 22),
            Err(HostIdentityError::EmptyHost)
        );
        assert_eq!(
            HostIdentity::parse("example.com:0", 22),
            Err(HostIdentityError::InvalidPort)
        );
        assert_eq!(
            HostIdentity::parse("[2001:db8::1", 22),
            Err(HostIdentityError::InvalidFormat)
        );
        assert_eq!(
            HostIdentity::parse("example\0.com", 22),
            Err(HostIdentityError::InvalidFormat)
        );
        assert_eq!(
            HostIdentity::parse("example.com,attacker.example", 22),
            Err(HostIdentityError::InvalidFormat)
        );
    }

    #[test]
    fn formats_openssh_sha256_fingerprint() {
        let fingerprint = fingerprint_sha256_from_base64("AQIDBA==").unwrap();
        assert_eq!(
            fingerprint,
            "SHA256:n2SnR+G5fxMfq7a0Rylsm28CAeefs8U1bmx36JtqgGo"
        );
        assert!(!fingerprint.contains('='));
    }

    #[test]
    fn rejects_invalid_fingerprint_input_without_echoing_it() {
        let secret_like_input = "%%%private-key-material%%%";
        let error = fingerprint_sha256_from_base64(secret_like_input).unwrap_err();
        assert_eq!(error, FingerprintError::InvalidBase64);
        assert!(!error.to_string().contains(secret_like_input));
    }
}
