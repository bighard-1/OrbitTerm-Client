use orbit_linux_domain::{AssetStorageScope, ServerAsset};
use orbit_linux_platform::CredentialMaterial;
use orbit_linux_sync::{
    account_storage_identifier, build_pull_preview_for_account, CloudClient, RemoteConfig,
    SyncError,
};
use std::collections::HashMap;
use std::env;
use uuid::Uuid;
use zeroize::Zeroizing;

fn required(name: &str) -> Zeroizing<String> {
    Zeroizing::new(env::var(name).unwrap_or_else(|_| panic!("missing required {name}")))
}

fn inventory(client: &CloudClient, tokens: &mut orbit_linux_sync::SyncTokens) -> Vec<RemoteConfig> {
    match client.pull_changes(tokens, 0) {
        Ok(batch) => batch.items,
        Err(SyncError::IncrementalUnavailable) => client
            .pull_inventory(tokens)
            .expect("compatibility inventory pull"),
        Err(error) => panic!("incremental pull failed: {error}"),
    }
}

fn record_for_asset(items: &[RemoteConfig], asset_id: Uuid) -> &RemoteConfig {
    let matches = items
        .iter()
        .filter(|item| {
            item.asset_id
                .as_deref()
                .and_then(|value| Uuid::parse_str(value).ok())
                == Some(asset_id)
        })
        .collect::<Vec<_>>();
    assert_eq!(matches.len(), 1, "expected one exact cloud asset UUID");
    matches[0]
}

#[test]
#[ignore = "deletes one recoverable fixture in an isolated real account"]
fn isolated_iphone_to_linux_soft_delete_by_exact_identity() {
    assert_eq!(
        env::var("ORBITTERM_SYNC_MATRIX_SCOPE").as_deref(),
        Ok("isolated-test-account"),
        "refusing to mutate a non-isolated account"
    );
    assert_eq!(
        env::var("ORBITTERM_CROSS_DELETE_CONFIRM").as_deref(),
        Ok("delete-exact-recoverable-fixture"),
        "explicit test-only deletion gate is required"
    );

    let username = required("ORBITTERM_TEST_USERNAME");
    let password = required("ORBITTERM_TEST_PASSWORD");
    let master_password = required("ORBITTERM_TEST_MASTER_PASSWORD");
    let target_id =
        Uuid::parse_str(&required("ORBITTERM_TEST_ASSET_ID")).expect("target asset UUID");
    let preserved_id = Uuid::parse_str(&required("ORBITTERM_TEST_PRESERVE_ASSET_ID"))
        .expect("preserved asset UUID");
    let expected_name = required("ORBITTERM_TEST_EXPECTED_NAME");
    let expected_host = required("ORBITTERM_TEST_EXPECTED_HOST");
    assert_ne!(target_id, preserved_id);

    let client = CloudClient::production().expect("production HTTPS client");
    let mut tokens = client
        .login(&username, &password)
        .expect("test account login");
    let account_scope = account_storage_identifier(&username).expect("canonical account scope");
    let before = inventory(&client, &mut tokens);
    let target = record_for_asset(&before, target_id);
    assert_eq!(target.state.as_deref().unwrap_or("active"), "active");
    assert_eq!(
        record_for_asset(&before, preserved_id)
            .state
            .as_deref()
            .unwrap_or("active"),
        "active",
        "the preserved RDP fixture must be active before deletion"
    );

    let preview = build_pull_preview_for_account(
        before.clone(),
        &[],
        &HashMap::new(),
        &master_password,
        &account_scope,
    )
    .expect("safe Linux decrypt preview");
    assert!(
        preview.failures.is_empty(),
        "no undecryptable fixtures allowed"
    );
    let candidates = preview
        .candidates
        .iter()
        .filter(|candidate| candidate.asset.id == target_id)
        .collect::<Vec<_>>();
    assert_eq!(candidates.len(), 1, "target must decrypt exactly once");
    assert_eq!(candidates[0].asset.name, *expected_name);
    assert_eq!(candidates[0].asset.host, *expected_host);
    assert_eq!(candidates[0].remote.id, target.id);

    let payload = client
        .prepare_delete(
            target_id,
            Uuid::new_v4(),
            Uuid::new_v4(),
            &target.vector_clock,
        )
        .expect("prepare exact Linux soft-delete payload");
    let response = client
        .execute_queued(&mut tokens, &payload)
        .expect("execute exact recoverable soft delete");
    assert_eq!(response.id, target.id, "remote numeric ID must not change");
    assert_eq!(response.state.as_deref(), Some("deleted"));

    let after = inventory(&client, &mut tokens);
    let deleted = record_for_asset(&after, target_id);
    assert_eq!(deleted.id, target.id);
    assert_eq!(deleted.state.as_deref(), Some("deleted"));
    assert_eq!(
        record_for_asset(&after, preserved_id)
            .state
            .as_deref()
            .unwrap_or("active"),
        "active",
        "the original RDP fixture must remain active"
    );
    println!("cross_device_linux_delete=PASS");
    println!("asset_id={target_id}");
    println!("remote_id={}", deleted.id);
    println!("deleted_revision={}", deleted.server_revision.unwrap_or(0));
    println!("preserved_asset_id={preserved_id}");
}

#[test]
#[ignore = "creates one recoverable fixture in an isolated real account"]
fn isolated_linux_to_iphone_create_by_exact_identity() {
    assert_eq!(
        env::var("ORBITTERM_SYNC_MATRIX_SCOPE").as_deref(),
        Ok("isolated-test-account"),
        "refusing to mutate a non-isolated account"
    );
    assert_eq!(
        env::var("ORBITTERM_CROSS_CREATE_CONFIRM").as_deref(),
        Ok("create-exact-recoverable-fixture"),
        "explicit test-only creation gate is required"
    );

    let username = required("ORBITTERM_TEST_USERNAME");
    let password = required("ORBITTERM_TEST_PASSWORD");
    let master_password = required("ORBITTERM_TEST_MASTER_PASSWORD");
    let preserved_id = Uuid::parse_str(&required("ORBITTERM_TEST_PRESERVE_ASSET_ID"))
        .expect("preserved asset UUID");
    let expected_name = required("ORBITTERM_TEST_EXPECTED_NAME");
    let expected_host = required("ORBITTERM_TEST_EXPECTED_HOST");
    assert_eq!(&*expected_name, "OT-Linux-iPhone-20261008");
    assert_eq!(&*expected_host, "192.0.2.27");

    let client = CloudClient::production().expect("production HTTPS client");
    let mut tokens = client
        .login(&username, &password)
        .expect("test account login");
    let account_scope = account_storage_identifier(&username).expect("canonical account scope");
    let before = inventory(&client, &mut tokens);
    assert_eq!(
        record_for_asset(&before, preserved_id)
            .state
            .as_deref()
            .unwrap_or("active"),
        "active",
        "the preserved RDP fixture must be active before creation"
    );
    let preview = build_pull_preview_for_account(
        before,
        &[],
        &HashMap::new(),
        &master_password,
        &account_scope,
    )
    .expect("safe Linux decrypt preview");
    assert!(
        preview.failures.is_empty(),
        "no undecryptable fixtures allowed"
    );
    assert!(
        preview
            .candidates
            .iter()
            .all(|candidate| candidate.asset.name != *expected_name),
        "do not create another active fixture with the same name"
    );

    let mut asset = ServerAsset::new(&*expected_name, &*expected_host, "qa_linux_iphone");
    asset.group = "Tombstone QA".into();
    asset.storage_scope = AssetStorageScope::AccountSynced;
    let credential = CredentialMaterial::password("QA-NotReal-Linux-iPhone-20261008!");
    let payload = client
        .prepare_new_upload_for_account(
            &asset,
            &credential,
            None,
            &master_password,
            Uuid::new_v4(),
            &account_scope,
        )
        .expect("prepare encrypted Linux-origin fixture");
    let response = client
        .execute_queued(&mut tokens, &payload)
        .expect("upload Linux-origin fixture");
    assert_eq!(response.state.as_deref().unwrap_or("active"), "active");
    assert_eq!(
        response
            .asset_id
            .as_deref()
            .and_then(|value| Uuid::parse_str(value).ok()),
        Some(asset.id)
    );
    let after = inventory(&client, &mut tokens);
    let uploaded = record_for_asset(&after, asset.id);
    assert_eq!(uploaded.id, response.id);
    assert_eq!(uploaded.state.as_deref().unwrap_or("active"), "active");
    assert_eq!(
        record_for_asset(&after, preserved_id)
            .state
            .as_deref()
            .unwrap_or("active"),
        "active"
    );
    println!("cross_device_linux_create=PASS");
    println!("asset_id={}", asset.id);
    println!("remote_id={}", uploaded.id);
    println!("active_revision={}", uploaded.server_revision.unwrap_or(0));
    println!("preserved_asset_id={preserved_id}");
}
