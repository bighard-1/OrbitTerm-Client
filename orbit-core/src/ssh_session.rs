use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, KeyboardInteractiveAuthResponse, Prompt};
use russh::keys::{decode_secret_key, PrivateKey, PrivateKeyWithHashAlg};

use crate::OrbitCoreError;

pub(crate) fn normalize_host_port(ip: &str, port: u16) -> String {
    let host = ip.trim();
    if host.is_empty() {
        return format!("127.0.0.1:{port}");
    }

    if host.starts_with('[') && host.contains("]:") {
        return host.to_string();
    }
    if host.matches(':').count() == 1 && !host.starts_with('[') {
        return host.to_string();
    }
    if host.matches(':').count() > 1 {
        if host.starts_with('[') {
            return format!("{host}:{port}");
        }
        return format!("[{host}]:{port}");
    }

    format!("{host}:{port}")
}

pub(crate) fn new_client_config() -> Arc<client::Config> {
    let config = client::Config {
        window_size: 8 * 1024 * 1024,
        maximum_packet_size: 256 * 1024,
        channel_buffer_size: 256,
        keepalive_interval: Some(Duration::from_secs(30)),
        keepalive_max: 3,
        nodelay: true,
        ..Default::default()
    };
    Arc::new(config)
}

/// Parses key material with the exact decoder used by live SSH sessions and
/// rejects legacy/hardware-backed algorithms that OrbitTerm cannot safely use
/// as a portable private key.  Keeping this check beside authentication avoids
/// the UI, encrypted sync and connection paths drifting apart.
pub(crate) fn decode_supported_private_key(
    private_key_content: &str,
    private_key_passphrase: &str,
) -> Result<PrivateKey, OrbitCoreError> {
    let passphrase = if private_key_passphrase.is_empty() {
        None
    } else {
        Some(private_key_passphrase)
    };
    let private_key = decode_secret_key(private_key_content.trim(), passphrase)
        .map_err(|_| OrbitCoreError::SshFailed("SSH 私钥无法解析，或私钥口令不正确".to_string()))?;
    let algorithm = private_key.algorithm();
    if private_key_algorithm_supported(&algorithm) {
        Ok(private_key)
    } else {
        Err(OrbitCoreError::SshFailed(format!(
            "不支持的 SSH 私钥算法: {}",
            algorithm.as_str()
        )))
    }
}

fn private_key_algorithm_supported(algorithm: &russh::keys::Algorithm) -> bool {
    matches!(
        algorithm.as_str(),
        "ssh-ed25519"
            | "ssh-rsa"
            | "rsa-sha2-256"
            | "rsa-sha2-512"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    )
}

pub(crate) async fn authenticate_ssh<H: client::Handler>(
    ssh_session: &mut client::Handle<H>,
    username: &str,
    password: &str,
    private_key_content: &str,
    private_key_passphrase: &str,
    allow_password_fallback: bool,
) -> Result<(), OrbitCoreError> {
    let trimmed_key = private_key_content.trim();
    let mut key_auth_failed = false;
    if !trimmed_key.is_empty() {
        let private_key = decode_supported_private_key(trimmed_key, private_key_passphrase)?;
        let hash_alg = ssh_session
            .best_supported_rsa_hash()
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?
            .flatten();

        let auth_result = ssh_session
            .authenticate_publickey(
                username.to_string(),
                PrivateKeyWithHashAlg::new(Arc::new(private_key), hash_alg),
            )
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

        if auth_result.success() {
            return Ok(());
        }

        key_auth_failed = true;
        if !allow_password_fallback {
            return Err(OrbitCoreError::SshFailed(
                "SSH 密钥认证失败（已禁用密码回退）".to_string(),
            ));
        }
    }

    if !password.is_empty() {
        let auth_result = ssh_session
            .authenticate_password(username.to_string(), password.to_string())
            .await
            .map_err(|e| OrbitCoreError::SshFailed(e.to_string()))?;

        if auth_result.success() {
            return Ok(());
        }

        // Some OpenSSH-for-Windows configurations expose password sign-in
        // through keyboard-interactive instead of the SSH "password" method.
        // Respond only to one explicit, non-echo password prompt; arbitrary
        // challenges (for example MFA or security questions) must never be
        // answered with the stored password.
        if authenticate_keyboard_interactive_password(ssh_session, username, password).await? {
            return Ok(());
        }

        if key_auth_failed {
            return Err(OrbitCoreError::SshFailed(
                "SSH 认证失败：密钥与密码均失败".to_string(),
            ));
        }
        return Err(OrbitCoreError::SshFailed("SSH 密码认证失败".to_string()));
    }

    if key_auth_failed {
        Err(OrbitCoreError::SshFailed(
            "SSH 认证失败：密钥失败且未提供可用密码".to_string(),
        ))
    } else {
        Err(OrbitCoreError::InvalidInput)
    }
}

async fn authenticate_keyboard_interactive_password<H: client::Handler>(
    ssh_session: &mut client::Handle<H>,
    username: &str,
    password: &str,
) -> Result<bool, OrbitCoreError> {
    let mut response = ssh_session
        .authenticate_keyboard_interactive_start(username.to_string(), None)
        .await
        .map_err(|error| OrbitCoreError::SshFailed(error.to_string()))?;

    // An SSH server may send an informational, prompt-free round before its
    // actual password prompt. Bound the exchange to avoid unbounded dialogs.
    for _ in 0..3 {
        match response {
            KeyboardInteractiveAuthResponse::Success => return Ok(true),
            KeyboardInteractiveAuthResponse::Failure { .. } => return Ok(false),
            KeyboardInteractiveAuthResponse::InfoRequest { prompts, .. } => {
                let Some(responses) = keyboard_interactive_password_responses(&prompts, password)
                else {
                    return Ok(false);
                };
                response = ssh_session
                    .authenticate_keyboard_interactive_respond(responses)
                    .await
                    .map_err(|error| OrbitCoreError::SshFailed(error.to_string()))?;
            }
        }
    }
    Ok(false)
}

#[cfg(test)]
mod private_key_policy_tests {
    use super::{decode_supported_private_key, private_key_algorithm_supported};
    use russh::keys::{ssh_key::LineEnding, Algorithm, EcdsaCurve, PrivateKey};

    #[test]
    fn portable_algorithm_allowlist_matches_the_connection_policy() {
        for algorithm in &[
            Algorithm::Ed25519,
            Algorithm::Rsa { hash: None },
            Algorithm::Ecdsa {
                curve: EcdsaCurve::NistP256,
            },
        ] {
            assert!(private_key_algorithm_supported(algorithm));
        }
        assert!(!private_key_algorithm_supported(&Algorithm::Dsa));
        assert!(!private_key_algorithm_supported(&Algorithm::SkEd25519));
    }

    #[test]
    fn portable_ed25519_material_uses_the_live_decoder() {
        let generated = PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519)
            .expect("generate runtime-only Ed25519 key");
        let encoded = generated
            .to_openssh(LineEnding::LF)
            .expect("encode runtime-only Ed25519 key");
        let decoded = decode_supported_private_key(&encoded, "").expect("supported Ed25519 key");
        assert_eq!(decoded.algorithm(), Algorithm::Ed25519);
    }
}

fn keyboard_interactive_password_responses(
    prompts: &[Prompt],
    password: &str,
) -> Option<Vec<String>> {
    let [prompt] = prompts else { return None };
    let normalized = prompt.prompt.trim().to_ascii_lowercase();
    if prompt.echo || !normalized.contains("password") {
        return None;
    }
    Some(vec![password.to_string()])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyboard_interactive_only_answers_one_non_echo_password_prompt() {
        let password = "not-a-real-secret";
        let prompt = Prompt {
            prompt: "Password: ".to_string(),
            echo: false,
        };
        assert_eq!(
            keyboard_interactive_password_responses(&[prompt], password),
            Some(vec![password.to_string()])
        );
    }

    #[test]
    fn keyboard_interactive_never_answers_arbitrary_or_echoed_prompts() {
        let password = "not-a-real-secret";
        for prompts in [
            vec![Prompt {
                prompt: "Verification code: ".to_string(),
                echo: false,
            }],
            vec![Prompt {
                prompt: "Password: ".to_string(),
                echo: true,
            }],
            vec![
                Prompt {
                    prompt: "Password: ".to_string(),
                    echo: false,
                },
                Prompt {
                    prompt: "OTP: ".to_string(),
                    echo: false,
                },
            ],
            vec![],
        ] {
            assert_eq!(
                keyboard_interactive_password_responses(&prompts, password),
                None
            );
        }
    }
}
