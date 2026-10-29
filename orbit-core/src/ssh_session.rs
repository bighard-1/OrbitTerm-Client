use std::sync::Arc;
use std::time::Duration;

use russh::client::{self, KeyboardInteractiveAuthResponse, Prompt};
use russh::keys::{decode_secret_key, PrivateKey, PrivateKeyWithHashAlg};
use russh::MethodKind;

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
    one_time_code: Option<&str>,
) -> Result<(), OrbitCoreError> {
    let trimmed_key = private_key_content.trim();
    let mut key_auth_failed = false;
    let mut key_partial_success = false;
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

        match auth_result {
            client::AuthResult::Success => return Ok(()),
            client::AuthResult::Failure {
                remaining_methods,
                partial_success: true,
            } => {
                key_partial_success = true;
                if remaining_methods.contains(&MethodKind::KeyboardInteractive) {
                    return authenticate_keyboard_interactive(
                        ssh_session,
                        username,
                        if allow_password_fallback {
                            password
                        } else {
                            ""
                        },
                        one_time_code,
                    )
                    .await
                    .and_then(authentication_result);
                }
                if !allow_password_fallback || !remaining_methods.contains(&MethodKind::Password) {
                    return Err(OrbitCoreError::SshFailed(
                        "SSH 服务器要求未支持的后续认证方式".to_string(),
                    ));
                }
            }
            client::AuthResult::Failure {
                remaining_methods, ..
            } => {
                key_auth_failed = true;
                if !allow_password_fallback
                    && remaining_methods.contains(&MethodKind::KeyboardInteractive)
                {
                    return authenticate_keyboard_interactive(
                        ssh_session,
                        username,
                        "",
                        one_time_code,
                    )
                    .await
                    .and_then(authentication_result);
                }
            }
        }
        if key_auth_failed && !allow_password_fallback {
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

        match auth_result {
            client::AuthResult::Success => return Ok(()),
            client::AuthResult::Failure {
                remaining_methods,
                partial_success: true,
            } if !remaining_methods.contains(&MethodKind::KeyboardInteractive) => {
                return Err(OrbitCoreError::SshFailed(
                    "SSH 服务器要求未支持的后续认证方式".to_string(),
                ));
            }
            _ => {}
        }

        // Some OpenSSH-for-Windows configurations expose password sign-in
        // through keyboard-interactive instead of the SSH "password" method.
        // Respond only to one explicit, non-echo password prompt; arbitrary
        // challenges (for example MFA or security questions) must never be
        // answered with the stored password.
        if authenticate_keyboard_interactive(ssh_session, username, password, one_time_code).await?
        {
            return Ok(());
        }

        if key_auth_failed {
            return Err(OrbitCoreError::SshFailed(
                "SSH 认证失败：密钥与密码均失败".to_string(),
            ));
        }
        return Err(OrbitCoreError::SshFailed("SSH 密码认证失败".to_string()));
    }

    if key_partial_success {
        Err(OrbitCoreError::SshFailed(
            "SSH 后续认证缺少可用凭据".to_string(),
        ))
    } else if key_auth_failed {
        Err(OrbitCoreError::SshFailed(
            "SSH 认证失败：密钥失败且未提供可用密码".to_string(),
        ))
    } else {
        Err(OrbitCoreError::InvalidInput)
    }
}

fn authentication_result(authenticated: bool) -> Result<(), OrbitCoreError> {
    if authenticated {
        Ok(())
    } else {
        Err(OrbitCoreError::SshFailed("SSH 二次认证失败".to_string()))
    }
}

async fn authenticate_keyboard_interactive<H: client::Handler>(
    ssh_session: &mut client::Handle<H>,
    username: &str,
    password: &str,
    one_time_code: Option<&str>,
) -> Result<bool, OrbitCoreError> {
    let mut response = ssh_session
        .authenticate_keyboard_interactive_start(username.to_string(), None)
        .await
        .map_err(|error| OrbitCoreError::SshFailed(error.to_string()))?;

    // An SSH server may send an informational, prompt-free round before its
    // actual password prompt. Bound the exchange to avoid unbounded dialogs.
    let mut code_used = false;
    for _ in 0..4 {
        match response {
            KeyboardInteractiveAuthResponse::Success => return Ok(true),
            KeyboardInteractiveAuthResponse::Failure { .. } => return Ok(false),
            KeyboardInteractiveAuthResponse::InfoRequest { prompts, .. } => {
                let responses = match keyboard_interactive_responses(
                    &prompts,
                    password,
                    one_time_code,
                    code_used,
                ) {
                    InteractiveResponse::Answers(values, used_code) => {
                        code_used |= used_code;
                        values
                    }
                    InteractiveResponse::NeedsCode => {
                        return Err(OrbitCoreError::SshSecondFactorRequired)
                    }
                    InteractiveResponse::Unsupported => return Ok(false),
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

#[derive(Debug, PartialEq, Eq)]
enum InteractiveResponse {
    Answers(Vec<String>, bool),
    NeedsCode,
    Unsupported,
}

fn keyboard_interactive_responses(
    prompts: &[Prompt],
    password: &str,
    one_time_code: Option<&str>,
    code_used: bool,
) -> InteractiveResponse {
    if prompts.len() > 2 {
        return InteractiveResponse::Unsupported;
    }
    let mut answers = Vec::with_capacity(prompts.len());
    let mut used_code = false;
    let mut used_password = false;
    for prompt in prompts {
        if prompt.echo {
            return InteractiveResponse::Unsupported;
        }
        let normalized = prompt.prompt.trim().to_lowercase();
        let is_code = [
            "verification code",
            "one-time",
            "one time",
            "otp",
            "2fa",
            "mfa",
            "authenticator",
            "passcode",
            "security code",
            "token",
            "code:",
            "验证码",
            "动态口令",
            "验证代码",
            "校验码",
        ]
        .iter()
        .any(|term| normalized.contains(term));
        if is_code {
            if code_used || used_code {
                return InteractiveResponse::Unsupported;
            }
            let Some(code) = one_time_code.filter(|value| !value.is_empty()) else {
                return InteractiveResponse::NeedsCode;
            };
            answers.push(code.to_string());
            used_code = true;
        } else if normalized.contains("password") && !password.is_empty() && !used_password {
            answers.push(password.to_string());
            used_password = true;
        } else {
            return InteractiveResponse::Unsupported;
        }
    }
    InteractiveResponse::Answers(answers, used_code)
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
            keyboard_interactive_responses(&[prompt], password, None, false),
            InteractiveResponse::Answers(vec![password.to_string()], false)
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
            assert_ne!(
                keyboard_interactive_responses(&prompts, password, None, false),
                InteractiveResponse::Answers(vec![password.to_string()], false)
            );
        }
    }

    #[test]
    fn otp_is_never_answered_with_saved_password() {
        let prompt = Prompt {
            prompt: "One-time password: ".into(),
            echo: false,
        };
        assert_eq!(
            keyboard_interactive_responses(
                std::slice::from_ref(&prompt),
                "stored-password",
                None,
                false
            ),
            InteractiveResponse::NeedsCode
        );
        assert_eq!(
            keyboard_interactive_responses(
                std::slice::from_ref(&prompt),
                "stored-password",
                Some("123456"),
                false
            ),
            InteractiveResponse::Answers(vec!["123456".into()], true)
        );
        assert_eq!(
            keyboard_interactive_responses(&[prompt], "stored-password", Some("123456"), true),
            InteractiveResponse::Unsupported
        );
    }

    #[tokio::test]
    async fn checked_authentication_completes_password_or_key_plus_code() {
        use russh::keys::ssh_key::LineEnding;
        use russh::server::{self, Auth, Response, Server as _};
        use russh::{keys::Algorithm, MethodSet};
        use std::borrow::Cow;
        use tokio::net::TcpListener;

        #[derive(Clone)]
        struct TestServer {
            key_first: bool,
            first_step_done: bool,
        }
        impl server::Server for TestServer {
            type Handler = Self;
            fn new_client(&mut self, _: Option<std::net::SocketAddr>) -> Self {
                Self {
                    key_first: self.key_first,
                    first_step_done: false,
                }
            }
        }
        impl server::Handler for TestServer {
            type Error = russh::Error;
            async fn auth_password(
                &mut self,
                _: &str,
                password: &str,
            ) -> Result<Auth, Self::Error> {
                if self.key_first || password != "test-primary" {
                    return Ok(Auth::reject());
                }
                self.first_step_done = true;
                Ok(Auth::Reject {
                    proceed_with_methods: Some(MethodSet::from(
                        &[MethodKind::KeyboardInteractive][..],
                    )),
                    partial_success: true,
                })
            }
            async fn auth_publickey(
                &mut self,
                _: &str,
                _: &russh::keys::ssh_key::PublicKey,
            ) -> Result<Auth, Self::Error> {
                if !self.key_first {
                    return Ok(Auth::reject());
                }
                self.first_step_done = true;
                Ok(Auth::Reject {
                    proceed_with_methods: Some(MethodSet::from(
                        &[MethodKind::KeyboardInteractive][..],
                    )),
                    partial_success: true,
                })
            }
            async fn auth_keyboard_interactive<'a>(
                &'a mut self,
                _: &str,
                _: &str,
                response: Option<Response<'a>>,
            ) -> Result<Auth, Self::Error> {
                if !self.first_step_done {
                    return Ok(Auth::reject());
                }
                match response {
                    None => Ok(Auth::Partial {
                        name: Cow::Borrowed("verification"),
                        instructions: Cow::Borrowed(""),
                        prompts: Cow::Borrowed(&[(Cow::Borrowed("Verification code: "), false)]),
                    }),
                    Some(mut response) => Ok(
                        if response.next().as_deref() == Some(b"123456".as_slice()) {
                            Auth::Accept
                        } else {
                            Auth::reject()
                        },
                    ),
                }
            }
        }
        #[derive(Clone)]
        struct TestHostKey;
        impl client::Handler for TestHostKey {
            type Error = OrbitCoreError;
            async fn check_server_key(
                &mut self,
                _: &russh::keys::PublicKeyOrCertificate,
            ) -> Result<bool, Self::Error> {
                Ok(true) // Isolated loopback fixture only; production uses CheckedHostKeyHandler.
            }
        }

        for key_first in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let host_key = PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519).unwrap();
            let client_key = PrivateKey::random(&mut rand10::rng(), Algorithm::Ed25519).unwrap();
            let encoded_key = client_key.to_openssh(LineEnding::LF).unwrap();
            let mut config = server::Config::default();
            config.keys.push(host_key);
            config.methods = MethodSet::from(
                &[
                    MethodKind::Password,
                    MethodKind::PublicKey,
                    MethodKind::KeyboardInteractive,
                ][..],
            );
            config.auth_rejection_time = Duration::from_millis(1);
            let task = tokio::spawn(async move {
                let mut server = TestServer {
                    key_first,
                    first_step_done: false,
                };
                let _ = server.run_on_socket(Arc::new(config), &listener).await;
            });
            for (code, expect_success) in [
                (None, false),
                (Some("123456"), true),
                (Some("wrong"), false),
            ] {
                let mut connection = client::connect(new_client_config(), address, TestHostKey)
                    .await
                    .unwrap();
                let result = authenticate_ssh(
                    &mut connection,
                    "fixture",
                    if key_first { "" } else { "test-primary" },
                    if key_first { &encoded_key } else { "" },
                    "",
                    false,
                    code,
                )
                .await;
                if expect_success {
                    assert!(result.is_ok(), "{result:?}");
                } else if code.is_none() {
                    assert!(
                        matches!(result, Err(OrbitCoreError::SshSecondFactorRequired)),
                        "{result:?}"
                    );
                } else {
                    assert!(result.is_err());
                }
            }
            task.abort();
        }
    }
}
