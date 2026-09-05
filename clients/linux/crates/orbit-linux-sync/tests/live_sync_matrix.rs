use orbit_linux_sync::{
    account_fingerprint, account_storage_identifier, build_pull_preview_for_account, CloudClient,
    SyncError,
};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::env;
use uuid::Uuid;
use zeroize::Zeroizing;

fn required(name: &str) -> Zeroizing<String> {
    Zeroizing::new(env::var(name).unwrap_or_else(|_| panic!("missing required {name}")))
}

#[test]
#[ignore = "requires an isolated real OrbitTerm test account"]
fn isolated_account_can_login_pull_and_decrypt_the_matrix_fixture() {
    assert_eq!(
        env::var("ORBITTERM_SYNC_MATRIX_SCOPE").as_deref(),
        Ok("isolated-test-account"),
        "refusing to run against an account that was not explicitly marked isolated"
    );
    let username = required("ORBITTERM_TEST_USERNAME");
    let password = required("ORBITTERM_TEST_PASSWORD");
    let master_password = required("ORBITTERM_TEST_MASTER_PASSWORD");
    let expected_asset = Uuid::parse_str(&required("ORBITTERM_TEST_ASSET_ID"))
        .expect("ORBITTERM_TEST_ASSET_ID must be a UUID");

    let client = CloudClient::production().expect("production HTTPS client");
    let mut tokens = client
        .login(&username, &password)
        .expect("real account login");
    let account_scope = account_storage_identifier(&username).expect("canonical account scope");
    let fingerprint = account_fingerprint(&tokens.access_token).expect("verifiable uid claim");
    assert_eq!(fingerprint.len(), 12);
    let remote = match client.pull_changes(&mut tokens, 0) {
        Ok(batch) => batch.items,
        Err(SyncError::IncrementalUnavailable) => client
            .pull_inventory(&mut tokens)
            .expect("compatibility inventory pull"),
        Err(error) => panic!("incremental pull failed: {error}"),
    };
    let preview = build_pull_preview_for_account(
        remote,
        &[],
        &HashMap::new(),
        &master_password,
        &account_scope,
    )
    .expect("safe preview");
    assert!(
        preview.failures.is_empty(),
        "isolated matrix account contains an unsupported or undecryptable fixture"
    );
    let fixture = preview
        .candidates
        .iter()
        .filter(|candidate| candidate.asset.id == expected_asset)
        .max_by_key(|candidate| candidate.remote.server_revision.unwrap_or(0))
        .expect("matrix fixture is missing, inactive, or could not be decrypted");
    let revision = fixture.remote.server_revision.expect("fixture revision");
    let vector_clock_sha = format!(
        "{:x}",
        Sha256::digest(fixture.remote.vector_clock.as_bytes())
    );
    println!("matrix_preflight=PASS");
    println!("account_fingerprint_suffix={}", &fingerprint[6..]);
    println!("asset_id={expected_asset}");
    println!("server_revision={revision}");
    println!("vector_clock_sha256={vector_clock_sha}");
}
