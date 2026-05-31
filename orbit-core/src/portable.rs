use serde::{Deserialize, Serialize};

use crate::{current_unix_secs, OrbitCoreError};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PortableServerConfigV1 {
    id: String,
    #[serde(default)]
    credential_id: String,
    name: String,
    #[serde(default)]
    group: String,
    host: String,
    port: u16,
    username: String,
    auth_method: String,
    #[serde(default = "default_transport")]
    transport: String,
    #[serde(default = "default_network_device_profile")]
    network_device_profile: String,
    #[serde(default = "default_allow_password_fallback")]
    allow_password_fallback: bool,
    #[serde(default)]
    password: String,
    #[serde(default)]
    private_key_content: String,
    #[serde(default)]
    private_key_passphrase: String,
    #[serde(default)]
    key_reference: String,
    #[serde(default)]
    saved_at_unix: u64,
}

fn default_transport() -> String {
    "ssh".to_string()
}

fn default_network_device_profile() -> String {
    "auto".to_string()
}

fn default_allow_password_fallback() -> bool {
    true
}

pub(crate) fn parse_portable_config(raw: &str) -> Result<PortableServerConfigV1, OrbitCoreError> {
    let mut config: PortableServerConfigV1 = serde_json::from_str(raw)
        .map_err(|_| OrbitCoreError::Internal("PortableServerConfig JSON 格式不合法".to_string()))?;

    if config.id.trim().is_empty()
        || config.name.trim().is_empty()
        || config.host.trim().is_empty()
        || config.username.trim().is_empty()
        || config.port == 0
    {
        return Err(OrbitCoreError::InvalidInput);
    }
    if config.credential_id.trim().is_empty() {
        config.credential_id = config.id.clone();
    }
    if config.saved_at_unix == 0 {
        config.saved_at_unix = current_unix_secs();
    }
    Ok(config)
}

pub(crate) fn portable_changed_fields(
    base: &PortableServerConfigV1,
    newer: &PortableServerConfigV1,
) -> Vec<&'static str> {
    let mut fields = Vec::new();
    if base.name != newer.name { fields.push("name"); }
    if base.group != newer.group { fields.push("group"); }
    if base.host != newer.host { fields.push("host"); }
    if base.port != newer.port { fields.push("port"); }
    if base.username != newer.username { fields.push("username"); }
    if base.auth_method != newer.auth_method { fields.push("authMethod"); }
    if base.transport != newer.transport { fields.push("transport"); }
    if base.network_device_profile != newer.network_device_profile { fields.push("networkDeviceProfile"); }
    if base.allow_password_fallback != newer.allow_password_fallback { fields.push("allowPasswordFallback"); }
    if base.password != newer.password { fields.push("password"); }
    if base.private_key_content != newer.private_key_content { fields.push("privateKeyContent"); }
    if base.private_key_passphrase != newer.private_key_passphrase { fields.push("privateKeyPassphrase"); }
    fields
}

pub(crate) fn portable_merge(
    remote: PortableServerConfigV1,
    local: PortableServerConfigV1,
    local_changed: &[String],
) -> PortableServerConfigV1 {
    let changed = |field: &str| local_changed.iter().any(|item| item == field);
    PortableServerConfigV1 {
        id: remote.id,
        credential_id: local.credential_id,
        name: if changed("name") { local.name } else { remote.name },
        group: if changed("group") { local.group } else { remote.group },
        host: if changed("host") { local.host } else { remote.host },
        port: if changed("port") { local.port } else { remote.port },
        username: if changed("username") { local.username } else { remote.username },
        auth_method: if changed("authMethod") { local.auth_method } else { remote.auth_method },
        transport: if changed("transport") { local.transport } else { remote.transport },
        network_device_profile: if changed("networkDeviceProfile") {
            local.network_device_profile
        } else {
            remote.network_device_profile
        },
        allow_password_fallback: if changed("allowPasswordFallback") {
            local.allow_password_fallback
        } else {
            remote.allow_password_fallback
        },
        password: if changed("password") { local.password } else { remote.password },
        private_key_content: if changed("privateKeyContent") {
            local.private_key_content
        } else {
            remote.private_key_content
        },
        private_key_passphrase: if changed("privateKeyPassphrase") {
            local.private_key_passphrase
        } else {
            remote.private_key_passphrase
        },
        key_reference: local.key_reference,
        saved_at_unix: current_unix_secs(),
    }
}
