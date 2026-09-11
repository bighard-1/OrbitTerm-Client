use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use orbit_linux_sync::{
    account_fingerprint, account_storage_identifier, build_pull_preview_for_account, CloudClient,
    PortableServerConfig, SyncError,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use zeroize::Zeroize;
use zeroize::Zeroizing;

fn required(name: &str) -> Zeroizing<String> {
    Zeroizing::new(env::var(name).unwrap_or_else(|_| panic!("missing required {name}")))
}

#[test]
#[ignore = "requires an isolated real OrbitTerm test account"]
fn isolated_account_inventory_is_decryptable_without_mutation() {
    assert_eq!(
        env::var("ORBITTERM_SYNC_MATRIX_SCOPE").as_deref(),
        Ok("isolated-test-account"),
        "refusing to run against an account that was not explicitly marked isolated"
    );
    let username = required("ORBITTERM_TEST_USERNAME");
    let password = required("ORBITTERM_TEST_PASSWORD");
    let master_password = required("ORBITTERM_TEST_MASTER_PASSWORD");

    let client = CloudClient::production().expect("production HTTPS client");
    let mut tokens = client
        .login(&username, &password)
        .expect("real account login");
    let account_scope = account_storage_identifier(&username).expect("canonical account scope");
    let fingerprint = account_fingerprint(&tokens.access_token).expect("verifiable uid claim");
    let remote = match client.pull_changes(&mut tokens, 0) {
        Ok(batch) => batch.items,
        Err(SyncError::IncrementalUnavailable) => client
            .pull_inventory(&mut tokens)
            .expect("compatibility inventory pull"),
        Err(error) => panic!("incremental pull failed: {error}"),
    };
    let active_count = remote
        .iter()
        .filter(|item| item.state.as_deref().unwrap_or("active") == "active")
        .count();
    let deleted_count = remote.len().saturating_sub(active_count);
    println!("inventory_audit=PASS");
    println!("account_fingerprint_suffix={}", &fingerprint[6..]);
    println!("active_items={active_count}");
    println!("deleted_items={deleted_count}");
    for item in remote
        .iter()
        .filter(|item| item.state.as_deref().unwrap_or("active") == "active")
    {
        println!(
            "active remote_id={} metadata_asset_id={} revision={}",
            item.id,
            item.asset_id.as_deref().unwrap_or("missing"),
            item.server_revision.unwrap_or(0)
        );
        if item
            .asset_id
            .as_deref()
            .is_none_or(|value| uuid::Uuid::parse_str(value).is_err())
        {
            let encrypted = BASE64
                .decode(item.encrypted_blob_base64.as_bytes())
                .expect("unbound record base64");
            let mut plaintext = if orbit_core::is_config_v2(&encrypted) {
                let mut root = orbit_core::derive_config_root_key_v2(
                    master_password.as_bytes(),
                    account_scope.as_bytes(),
                )
                .expect("unbound record account root");
                let result = orbit_core::decrypt_config_v2(&root, &encrypted)
                    .expect("unbound OTC2 record decrypt");
                root.zeroize();
                result
            } else {
                orbit_core::decrypt_config(master_password.to_string(), encrypted)
                    .expect("unbound OTC1 record decrypt")
            };
            match serde_json::from_slice::<PortableServerConfig>(&plaintext) {
                Ok(portable) => println!(
                    "unbound_payload remote_id={} portable_asset_id={} name_sha256={:x}",
                    item.id,
                    portable.id,
                    Sha256::digest(portable.name.as_bytes())
                ),
                Err(_) => {
                    let value: serde_json::Value =
                        serde_json::from_slice(&plaintext).expect("unbound JSON payload");
                    let mut keys = value
                        .as_object()
                        .expect("unbound JSON object")
                        .keys()
                        .cloned()
                        .collect::<Vec<_>>();
                    keys.sort();
                    let name_hash = value
                        .get("name")
                        .and_then(serde_json::Value::as_str)
                        .map(|name| format!("{:x}", Sha256::digest(name.as_bytes())))
                        .unwrap_or_else(|| "missing".into());
                    println!(
                        "unbound_auxiliary_payload remote_id={} keys={} name_sha256={name_hash}",
                        item.id,
                        keys.join(",")
                    );
                }
            }
            plaintext.zeroize();
        }
    }
    for item in remote
        .iter()
        .filter(|item| item.state.as_deref() == Some("deleted"))
    {
        println!(
            "restorable remote_id={} metadata_asset_id={} revision={}",
            item.id,
            item.asset_id.as_deref().unwrap_or("missing"),
            item.server_revision.unwrap_or(0)
        );
    }
    let preview = build_pull_preview_for_account(
        remote,
        &[],
        &HashMap::new(),
        &master_password,
        &account_scope,
    )
    .expect("safe preview");
    println!("decryptable_active_items={}", preview.candidates.len());
    println!("recognized_auxiliary_records={}", preview.auxiliary_records);
    println!("undecryptable_or_invalid_items={}", preview.failures.len());
    for candidate in &preview.candidates {
        println!(
            "asset id={} remote_id={} metadata_asset_id={} revision={} name_sha256={:x}",
            candidate.asset.id,
            candidate.remote.id,
            candidate.remote.asset_id.as_deref().unwrap_or("missing"),
            candidate.remote.server_revision.unwrap_or(0),
            Sha256::digest(candidate.asset.name.as_bytes())
        );
    }
    for failure in &preview.failures {
        println!(
            "failure asset_id={} reason={}",
            failure
                .asset_id
                .map(|value| value.to_string())
                .unwrap_or_else(|| "unbound".into()),
            failure.reason
        );
    }
}
