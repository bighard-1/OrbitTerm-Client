use std::fs;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use rand::random;

use super::{
    AddRevokedKeyOutcome, AddTrustedKeyOutcome, HostIdentity, HostKeyState, KnownHostMarker,
    KnownHostsStore, KnownHostsStoreError, KnownHostsStoreWarning, ReplaceTrustedKeyOutcome,
};

const KEY_A: &str = "AQIDBA==";
const KEY_B: &str = "BQYHCA==";

#[test]
fn missing_file_loads_as_empty_store() {
    let directory = TestDirectory::new();
    let store = KnownHostsStore::load(directory.path().join("missing_known_hosts")).unwrap();
    assert_eq!(store.records().count(), 0);
    assert!(store.warnings().is_empty());
}

#[test]
fn empty_file_loads_successfully() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, b"").unwrap();
    let store = KnownHostsStore::load(path).unwrap();
    assert_eq!(store.records().count(), 0);
    assert_eq!(store.to_text(), "");
}

#[test]
fn load_preserves_comments_blank_lines_and_malformed_lines() {
    let source = format!(
        "# managed outside OrbitTerm\n\nmalformed line\nexample.com ssh-ed25519 {KEY_A} note\n"
    );
    let store = KnownHostsStore::from_text(&source).unwrap();
    assert_eq!(store.records().count(), 1);
    assert!(store
        .warnings()
        .iter()
        .any(|warning| matches!(warning, KnownHostsStoreWarning::Parser(_))));
    assert_eq!(store.to_text(), source);
}

#[test]
fn invalid_utf8_is_rejected() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, [0xff, 0xfe, 0xfd]).unwrap();
    assert_eq!(
        KnownHostsStore::load(path).unwrap_err(),
        KnownHostsStoreError::InvalidUtf8
    );
}

#[test]
fn oversized_file_is_rejected() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, vec![b'a'; 33]).unwrap();
    assert_eq!(
        KnownHostsStore::load_with_limit(path, 32).unwrap_err(),
        KnownHostsStoreError::FileTooLarge { max_bytes: 32 }
    );
}

#[test]
fn atomic_save_creates_reloadable_file_without_temp_residue() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, "legacy contents").unwrap();
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, Some("primary"))
        .unwrap();

    store.save(&path).unwrap();
    let loaded = KnownHostsStore::load(&path).unwrap();
    assert_eq!(
        loaded.query(&identity, "ssh-ed25519", KEY_A).state,
        HostKeyState::Trusted
    );

    let entries = fs::read_dir(directory.path())
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect::<Vec<_>>();
    assert_eq!(entries, vec![path.file_name().unwrap()]);
}

#[test]
fn atomic_replace_failure_cleans_temp_file_and_preserves_destination() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::create_dir(&path).unwrap();
    fs::write(path.join("sentinel"), "untouched").unwrap();

    let store = KnownHostsStore::empty();
    assert!(matches!(
        store.save(&path),
        Err(KnownHostsStoreError::AtomicReplaceFailed { .. })
    ));
    assert_eq!(
        fs::read_to_string(path.join("sentinel")).unwrap(),
        "untouched"
    );
    let temporary_files = fs::read_dir(directory.path())
        .unwrap()
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .starts_with(".orbitterm-known-hosts-")
        })
        .count();
    assert_eq!(temporary_files, 0);
}

#[test]
fn failed_save_precondition_preserves_existing_file() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, "original contents").unwrap();

    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty_with_limit(8);
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
        .unwrap();
    assert_eq!(
        store.save(&path).unwrap_err(),
        KnownHostsStoreError::FileTooLarge { max_bytes: 8 }
    );
    assert_eq!(fs::read_to_string(path).unwrap(), "original contents");
}

#[cfg(unix)]
#[test]
fn saved_file_uses_owner_only_permissions() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    let store = KnownHostsStore::empty();
    store.save(&path).unwrap();
    let mode = fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}

#[cfg(unix)]
#[test]
fn load_warns_about_broad_existing_permissions() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    fs::write(&path, format!("example.com ssh-ed25519 {KEY_A}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    let store = KnownHostsStore::load(path).unwrap();
    assert!(store.warnings().iter().any(|warning| matches!(
        warning,
        KnownHostsStoreWarning::InsecurePermissions { mode: 0o644 }
    )));
}

#[test]
fn comment_control_characters_are_sanitized() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(
            &identity,
            "ssh-ed25519",
            KEY_A,
            Some("first\nsecond\0third\tlast"),
        )
        .unwrap();
    let serialized = store.to_text();
    assert!(serialized.contains("first second third last"));
    assert!(!serialized.contains('\0'));
}

#[test]
fn serialization_round_trip_retains_supported_and_preserved_content() {
    let source =
        format!("# heading\n@cert-authority *.example.com ssh-ed25519 {KEY_A}\nmalformed\n");
    let store = KnownHostsStore::from_text(&source).unwrap();
    let reparsed = KnownHostsStore::from_text(&store.to_text()).unwrap();
    assert_eq!(reparsed.to_text(), source);
    assert_eq!(reparsed.records().count(), 1);
    assert_eq!(
        reparsed.records().next().unwrap().marker,
        KnownHostMarker::CertAuthority
    );
}

#[test]
fn adding_trusted_keys_is_idempotent_and_detects_changes() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
            .unwrap(),
        AddTrustedKeyOutcome::Added
    );
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
            .unwrap(),
        AddTrustedKeyOutcome::AlreadyTrusted
    );
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", KEY_B, None)
            .unwrap_err(),
        KnownHostsStoreError::ChangedKeyConflict
    );
    assert_eq!(store.records().count(), 1);
}

#[test]
fn same_host_can_trust_a_new_algorithm_without_overwriting_existing_key() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
        .unwrap();
    store
        .add_trusted_key(&identity, "ecdsa-sha2-nistp256", KEY_B, None)
        .unwrap();
    assert_eq!(store.records().count(), 2);
    assert_eq!(
        store.query(&identity, "ecdsa-sha2-nistp256", KEY_B).state,
        HostKeyState::Trusted
    );
}

#[test]
fn add_uses_openssh_port_token_and_keeps_dns_separate_from_ip() {
    let dns = HostIdentity::parse("Example.COM", 2222).unwrap();
    let ip = HostIdentity::parse("192.0.2.10", 2222).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&dns, "ssh-ed25519", KEY_A, None)
        .unwrap();
    store
        .add_trusted_key(&ip, "ssh-ed25519", KEY_B, None)
        .unwrap();
    let text = store.to_text();
    assert!(text.contains("[example.com]:2222"));
    assert!(text.contains("[192.0.2.10]:2222"));
    assert_eq!(
        store.query(&dns, "ssh-ed25519", KEY_B).state,
        HostKeyState::Changed
    );
}

#[test]
fn invalid_key_and_algorithm_are_rejected() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", "%%%", None)
            .unwrap_err(),
        KnownHostsStoreError::InvalidPublicKey
    );
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh ed25519", KEY_A, None)
            .unwrap_err(),
        KnownHostsStoreError::InvalidAlgorithm
    );
    let oversized_key = "A".repeat(64 * 1024 + 1);
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", &oversized_key, None)
            .unwrap_err(),
        KnownHostsStoreError::InvalidPublicKey
    );
}

#[test]
fn revoked_key_cannot_be_overridden_by_trusted_add() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    assert_eq!(
        store
            .mark_revoked(&identity, "ssh-ed25519", KEY_A, Some("retired"))
            .unwrap(),
        AddRevokedKeyOutcome::Added
    );
    assert_eq!(
        store
            .mark_revoked(&identity, "ssh-ed25519", KEY_A, None)
            .unwrap(),
        AddRevokedKeyOutcome::AlreadyRevoked
    );
    assert_eq!(
        store
            .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
            .unwrap_err(),
        KnownHostsStoreError::RevokedConflict
    );
}

#[test]
fn delete_specific_trusted_key_preserves_other_host_patterns_and_revocations() {
    let source = format!(
        "example.com,alias.example.com ssh-ed25519 {KEY_A}\n@revoked example.com ssh-ed25519 {KEY_B}\n"
    );
    let mut store = KnownHostsStore::from_text(&source).unwrap();
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let alias = HostIdentity::parse("alias.example.com", 22).unwrap();

    assert_eq!(
        store.remove_trusted_key(&identity, "ssh-ed25519").unwrap(),
        1
    );
    assert_eq!(
        store.query(&identity, "ssh-ed25519", KEY_A).state,
        HostKeyState::Changed
    );
    assert_eq!(
        store.query(&alias, "ssh-ed25519", KEY_A).state,
        HostKeyState::Trusted
    );
    assert!(store.to_text().contains("@revoked example.com"));
}

#[test]
fn delete_all_trusted_does_not_cross_port_or_identity_boundaries() {
    let default_dns = HostIdentity::parse("example.com", 22).unwrap();
    let custom_dns = HostIdentity::parse("example.com", 2222).unwrap();
    let ip = HostIdentity::parse("192.0.2.10", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&default_dns, "ssh-ed25519", KEY_A, None)
        .unwrap();
    store
        .add_trusted_key(&custom_dns, "ssh-ed25519", KEY_A, None)
        .unwrap();
    store
        .add_trusted_key(&ip, "ssh-ed25519", KEY_A, None)
        .unwrap();

    assert_eq!(store.remove_all_trusted(&default_dns), 1);
    assert_eq!(
        store.query(&custom_dns, "ssh-ed25519", KEY_A).state,
        HostKeyState::Trusted
    );
    assert_eq!(
        store.query(&ip, "ssh-ed25519", KEY_A).state,
        HostKeyState::Trusted
    );
}

#[test]
fn revoked_removal_requires_explicit_api() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .mark_revoked(&identity, "ssh-ed25519", KEY_A, None)
        .unwrap();
    assert_eq!(
        store.remove_trusted_key(&identity, "ssh-ed25519").unwrap(),
        0
    );
    assert_eq!(
        store.query(&identity, "ssh-ed25519", KEY_A).state,
        HostKeyState::Revoked
    );
    assert_eq!(store.remove_revoked(&identity, "ssh-ed25519").unwrap(), 1);
}

#[test]
fn delete_save_and_reload_are_consistent() {
    let directory = TestDirectory::new();
    let path = directory.path().join("known_hosts");
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, None)
        .unwrap();
    store.remove_trusted_key(&identity, "ssh-ed25519").unwrap();
    store.save(&path).unwrap();
    let reloaded = KnownHostsStore::load(path).unwrap();
    assert_eq!(reloaded.records().count(), 0);
}

#[test]
fn explicit_replace_requires_expected_old_key_and_updates_record() {
    let identity = HostIdentity::parse("example.com", 22).unwrap();
    let mut store = KnownHostsStore::empty();
    store
        .add_trusted_key(&identity, "ssh-ed25519", KEY_A, Some("old"))
        .unwrap();
    assert_eq!(
        store
            .replace_trusted_key(
                &identity,
                "ssh-ed25519",
                KEY_A,
                KEY_B,
                Some("confirmed rotation"),
            )
            .unwrap(),
        ReplaceTrustedKeyOutcome::Updated
    );
    assert_eq!(
        store.query(&identity, "ssh-ed25519", KEY_B).state,
        HostKeyState::Trusted
    );
    assert_eq!(
        store
            .replace_trusted_key(&identity, "ssh-ed25519", KEY_A, KEY_B, None)
            .unwrap(),
        ReplaceTrustedKeyOutcome::AlreadyTrusted
    );
}

#[test]
fn explicit_replace_rejects_a_broader_pattern_that_still_trusts_the_old_key() {
    let identity = HostIdentity::parse("api.example.com", 22).unwrap();
    let source = format!("api.example.com,*.example.com ssh-ed25519 {KEY_A}\n");
    let mut store = KnownHostsStore::from_text(&source).unwrap();
    assert_eq!(
        store
            .replace_trusted_key(&identity, "ssh-ed25519", KEY_A, KEY_B, None)
            .unwrap_err(),
        KnownHostsStoreError::AmbiguousHostPattern
    );
    assert_eq!(store.to_text(), source);
}

struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "orbitterm-known-hosts-test-{}-{:016x}",
            std::process::id(),
            random::<u64>()
        ));
        fs::create_dir_all(&path).unwrap();
        Self { path }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
