use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Non-secret server metadata owned by the Linux presentation layer.
/// Passwords, private keys, and passphrases are deliberately not representable here.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerAsset {
    pub id: Uuid,
    pub credential_id: Uuid,
    pub name: String,
    pub group: String,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: AuthMethod,
    pub transport: Transport,
    pub allow_password_fallback: bool,
    pub key_reference: String,
    pub tags: Vec<String>,
    #[serde(default)]
    pub jump_host: Option<JumpHostConfiguration>,
}

impl ServerAsset {
    pub fn new(
        name: impl Into<String>,
        host: impl Into<String>,
        username: impl Into<String>,
    ) -> Self {
        let id = Uuid::new_v4();
        Self {
            id,
            credential_id: id,
            name: name.into(),
            group: String::new(),
            host: host.into(),
            port: 22,
            username: username.into(),
            auth_method: AuthMethod::Password,
            transport: Transport::Ssh,
            allow_password_fallback: false,
            key_reference: String::new(),
            tags: Vec::new(),
            jump_host: None,
        }
    }

    pub fn validate(&self) -> Result<(), AssetValidationError> {
        if self.name.trim().is_empty()
            || self.name.len() > 128
            || self.name.chars().any(char::is_control)
        {
            return Err(AssetValidationError::MissingName);
        }
        if self.host.trim().is_empty()
            || self.host.len() > 255
            || self
                .host
                .chars()
                .any(|character| character.is_whitespace() || character.is_control())
        {
            return Err(AssetValidationError::InvalidHost);
        }
        if self.port == 0 {
            return Err(AssetValidationError::InvalidPort);
        }
        if self.username.trim().is_empty()
            || self.username.len() > 255
            || self.username.chars().any(char::is_control)
        {
            return Err(AssetValidationError::MissingUsername);
        }
        if self.group.len() > 128
            || self.tags.len() > 64
            || self
                .tags
                .iter()
                .any(|tag| tag.len() > 64 || tag.is_empty() || tag.chars().any(char::is_control))
        {
            return Err(AssetValidationError::InvalidMetadata);
        }
        if self.key_reference.len() > 255
            || self.key_reference.contains('/')
            || self.key_reference.contains('\\')
            || self.key_reference.chars().any(char::is_control)
        {
            return Err(AssetValidationError::PlatformPathInKeyReference);
        }
        if self.transport != Transport::Ssh
            && (self.auth_method != AuthMethod::Password || !self.key_reference.is_empty())
        {
            return Err(AssetValidationError::UnsupportedAuthForTransport);
        }
        if let Some(jump) = &self.jump_host {
            if self.transport != Transport::Ssh
                || jump.credential_id == self.credential_id
                || jump.host.trim().is_empty()
                || jump.host.len() > 255
                || jump
                    .host
                    .chars()
                    .any(|character| character.is_whitespace() || character.is_control())
                || jump.port == 0
                || jump.username.trim().is_empty()
                || jump.username.len() > 255
                || jump.username.chars().any(char::is_control)
                || jump.key_reference.len() > 255
                || jump.key_reference.contains('/')
                || jump.key_reference.contains('\\')
                || jump.key_reference.chars().any(char::is_control)
            {
                return Err(AssetValidationError::InvalidJumpHost);
            }
        }
        Ok(())
    }

    pub fn endpoint(&self) -> String {
        format!(
            "{}@{}:{}",
            self.username.trim(),
            self.host.trim(),
            self.port
        )
    }

    pub fn matches(&self, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        query.is_empty()
            || self.name.to_lowercase().contains(&query)
            || self.host.to_lowercase().contains(&query)
            || self.username.to_lowercase().contains(&query)
            || self.group.to_lowercase().contains(&query)
            || self
                .transport
                .display_name()
                .to_lowercase()
                .contains(&query)
            || self
                .tags
                .iter()
                .any(|tag| tag.to_lowercase().contains(&query))
    }
}

/// Non-secret metadata for one independently verified SSH jump host.
/// Its credential is stored under `credential_id`, never in the asset JSON.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JumpHostConfiguration {
    pub credential_id: Uuid,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth_method: AuthMethod,
    pub allow_password_fallback: bool,
    #[serde(default)]
    pub key_reference: String,
}

impl JumpHostConfiguration {
    pub fn endpoint(&self) -> String {
        format!(
            "{}@{}:{}",
            self.username.trim(),
            self.host.trim(),
            self.port
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthMethod {
    #[default]
    Password,
    Key,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Transport {
    #[default]
    Ssh,
    Telnet,
    Rdp,
}

impl Transport {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Ssh => "SSH",
            Self::Telnet => "Telnet",
            Self::Rdp => "RDP",
        }
    }

    pub fn default_port(self) -> u16 {
        match self {
            Self::Ssh => 22,
            Self::Telnet => 23,
            Self::Rdp => 3389,
        }
    }

    pub fn supports_checked_ssh(self) -> bool {
        self == Self::Ssh
    }
}

#[derive(Clone, Debug, Error, PartialEq, Eq)]
pub enum AssetValidationError {
    #[error("服务器名称不能为空")]
    MissingName,
    #[error("主机地址不能为空且不能包含空格")]
    InvalidHost,
    #[error("端口必须在 1–65535 范围内")]
    InvalidPort,
    #[error("用户名不能为空")]
    MissingUsername,
    #[error("分组或标签不符合长度与字符限制")]
    InvalidMetadata,
    #[error("密钥引用只能保存文件名提示，不能包含平台路径")]
    PlatformPathInKeyReference,
    #[error("Telnet 与 RDP 资产只能使用密码凭据，不能携带 SSH 私钥引用")]
    UnsupportedAuthForTransport,
    #[error("跳板机配置无效，或与目标资产错误复用了同一凭据")]
    InvalidJumpHost,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_model_never_contains_secret_fields() {
        let json = serde_json::to_value(ServerAsset::new("边缘节点", "10.0.0.8", "ops"))
            .expect("asset serializes");
        let object = json.as_object().expect("object");
        for forbidden in ["password", "privateKeyContent", "privateKeyPassphrase"] {
            assert!(!object.contains_key(forbidden));
        }
    }

    #[test]
    fn key_reference_refuses_platform_paths() {
        let mut asset = ServerAsset::new("边缘节点", "10.0.0.8", "ops");
        asset.key_reference = "/home/ops/.ssh/id_ed25519".into();
        assert_eq!(
            asset.validate(),
            Err(AssetValidationError::PlatformPathInKeyReference)
        );
    }

    #[test]
    fn search_covers_operational_fields() {
        let mut asset = ServerAsset::new("数据库主机", "db.internal", "postgres");
        asset.group = "生产环境".into();
        asset.tags = vec!["华东".into()];
        assert!(asset.matches("postgres"));
        assert!(asset.matches("生产"));
        assert!(asset.matches("华东"));
        assert!(asset.matches("ssh"));
        assert!(!asset.matches("测试"));
    }

    #[test]
    fn all_cross_platform_transports_round_trip_without_ssh_reinterpretation() {
        for (transport, label, port) in [
            (Transport::Ssh, "SSH", 22),
            (Transport::Telnet, "Telnet", 23),
            (Transport::Rdp, "RDP", 3389),
        ] {
            let encoded = serde_json::to_string(&transport).unwrap();
            let decoded: Transport = serde_json::from_str(&encoded).unwrap();
            assert_eq!(decoded, transport);
            assert_eq!(decoded.display_name(), label);
            assert_eq!(decoded.default_port(), port);
        }
    }

    #[test]
    fn non_ssh_assets_cannot_retain_key_authentication() {
        let mut asset = ServerAsset::new("远程桌面", "rdp.example", "administrator");
        asset.transport = Transport::Rdp;
        asset.port = asset.transport.default_port();
        asset.auth_method = AuthMethod::Key;
        assert_eq!(
            asset.validate(),
            Err(AssetValidationError::UnsupportedAuthForTransport)
        );
    }

    #[test]
    fn jump_host_requires_ssh_and_distinct_credentials() {
        let mut asset = ServerAsset::new("数据库", "db.internal", "ops");
        asset.jump_host = Some(JumpHostConfiguration {
            credential_id: asset.credential_id,
            host: "bastion.internal".into(),
            port: 22,
            username: "jump".into(),
            auth_method: AuthMethod::Password,
            allow_password_fallback: false,
            key_reference: String::new(),
        });
        assert_eq!(asset.validate(), Err(AssetValidationError::InvalidJumpHost));
        asset.jump_host.as_mut().unwrap().credential_id = Uuid::new_v4();
        assert!(asset.validate().is_ok());
    }
}
