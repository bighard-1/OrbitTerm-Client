use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, KeyboardInteractiveAuthResponse, Prompt};
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};

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
        keepalive_interval: Some(Duration::from_secs(30)),
        keepalive_max: 3,
        ..Default::default()
    };
    Arc::new(config)
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
        let passphrase = if private_key_passphrase.is_empty() {
            None
        } else {
            Some(private_key_passphrase)
        };

        let private_key = decode_secret_key(trimmed_key, passphrase)
            .map_err(|e| OrbitCoreError::SshFailed(format!("私钥解析失败: {e}")))?;
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
