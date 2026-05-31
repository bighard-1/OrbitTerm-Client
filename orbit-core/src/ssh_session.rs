use std::sync::Arc;
use std::time::Duration;

use russh::client;
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};

use crate::{OrbitCoreError, OrbitSshClientHandler};

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
    let mut config = client::Config::default();
    config.keepalive_interval = Some(Duration::from_secs(30));
    config.keepalive_max = 3;
    Arc::new(config)
}

pub(crate) async fn authenticate_ssh(
    ssh_session: &mut client::Handle<OrbitSshClientHandler>,
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
