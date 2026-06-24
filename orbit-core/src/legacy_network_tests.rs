use std::sync::atomic::{AtomicUsize, Ordering};

use crate::legacy_network::{
    LegacyNetworkDisabled, LegacyNetworkGate, LegacyNetworkPolicy, LEGACY_NETWORK_DISABLED_CODE,
};
use crate::security::{
    fingerprint_sha256, HostIdentity, SessionLifecycleState, SessionSecurityGeneration,
    TrustStoreGeneration,
};
use crate::session_pool::{
    insert_synthetic_base_session_for_tests, remove_synthetic_base_session_for_tests,
    require_active_verified_base_session, require_sftp_operation_metadata_access_with_policy,
    SftpSessionMetadata, SftpSessionSource,
};
use crate::terminal::{
    insert_synthetic_terminal_channel_for_tests, remove_synthetic_terminal_channel_for_tests,
    require_terminal_operation_access_with_policy, TerminalChannelMetadata,
};
use crate::OrbitCoreError;

fn verified_generation() -> SessionSecurityGeneration {
    SessionSecurityGeneration::HostKeyVerified {
        host_identity: HostIdentity::parse("release-gate.example", 22).unwrap(),
        key_algorithm: "ssh-ed25519".to_string(),
        fingerprint_sha256: fingerprint_sha256(b"release-gate-key"),
        trust_store_generation: TrustStoreGeneration::from_contents(b"release-gate-store"),
    }
}

#[test]
fn policy_is_compile_time_only_and_public_release_is_fail_closed() {
    assert_eq!(
        LegacyNetworkGate::require(LegacyNetworkPolicy::DisabledInPublicRelease),
        Err(LegacyNetworkDisabled)
    );
    assert_eq!(
        LegacyNetworkGate::require(LegacyNetworkPolicy::AllowedInternal),
        Ok(())
    );

    if cfg!(feature = "legacy-network-internal") {
        assert_eq!(
            LegacyNetworkPolicy::current(),
            LegacyNetworkPolicy::AllowedInternal
        );
    } else {
        assert_eq!(
            LegacyNetworkPolicy::current(),
            LegacyNetworkPolicy::DisabledInPublicRelease
        );
    }
}

#[test]
fn denied_policy_stops_work_before_backend_and_has_a_redacted_stable_code() {
    let calls = AtomicUsize::new(0);
    let result = LegacyNetworkGate::require(LegacyNetworkPolicy::DisabledInPublicRelease)
        .map(|()| calls.fetch_add(1, Ordering::SeqCst));
    assert_eq!(result, Err(LegacyNetworkDisabled));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        LegacyNetworkDisabled.error_code(),
        LEGACY_NETWORK_DISABLED_CODE
    );
    assert_eq!(LegacyNetworkDisabled.to_string(), "legacy_network_disabled");

    let output = format!("{LegacyNetworkDisabled:?} {LegacyNetworkDisabled}");
    for forbidden in [
        "release-gate.example",
        "username",
        "password",
        "private_key",
        "known_hosts",
        "command",
        "public_key",
    ] {
        assert!(!output.contains(forbidden));
    }
}

#[cfg(not(feature = "legacy-network-internal"))]
#[test]
fn environment_variables_cannot_enable_public_release_legacy_network() {
    const VARIABLE: &str = "ORBIT_CORE_ENABLE_LEGACY_NETWORK";
    std::env::set_var(VARIABLE, "1");
    let decision = LegacyNetworkGate::require_current();
    std::env::remove_var(VARIABLE);
    assert_eq!(decision, Err(LegacyNetworkDisabled));
}

#[test]
fn public_policy_allows_only_checked_sftp_operation_metadata() {
    let checked = insert_synthetic_base_session_for_tests(
        "release-gate.example",
        "root",
        verified_generation(),
    )
    .unwrap();
    let guard = require_active_verified_base_session(checked.id).unwrap();
    let checked_metadata = SftpSessionMetadata::checked(&guard);
    assert!(require_sftp_operation_metadata_access_with_policy(
        &checked,
        &checked_metadata,
        LegacyNetworkPolicy::DisabledInPublicRelease,
    )
    .is_ok());

    let legacy = insert_synthetic_base_session_for_tests(
        "legacy-release-gate.example",
        "root",
        SessionSecurityGeneration::LegacyUnverified,
    )
    .unwrap();
    let legacy_metadata = SftpSessionMetadata::new(&legacy, SftpSessionSource::Legacy);
    assert!(matches!(
        require_sftp_operation_metadata_access_with_policy(
            &legacy,
            &legacy_metadata,
            LegacyNetworkPolicy::DisabledInPublicRelease,
        ),
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(require_sftp_operation_metadata_access_with_policy(
        &legacy,
        &legacy_metadata,
        LegacyNetworkPolicy::AllowedInternal,
    )
    .is_ok());

    remove_synthetic_base_session_for_tests(checked.id);
    remove_synthetic_base_session_for_tests(legacy.id);
}

#[test]
fn checked_sftp_operation_revalidates_lifecycle_and_generation() {
    let base = insert_synthetic_base_session_for_tests(
        "release-gate.example",
        "root",
        verified_generation(),
    )
    .unwrap();
    let guard = require_active_verified_base_session(base.id).unwrap();
    let metadata = SftpSessionMetadata::checked(&guard);
    base.metadata
        .transition_to(SessionLifecycleState::Draining)
        .unwrap();
    assert!(require_sftp_operation_metadata_access_with_policy(
        &base,
        &metadata,
        LegacyNetworkPolicy::DisabledInPublicRelease,
    )
    .is_err());
    remove_synthetic_base_session_for_tests(base.id);
}

#[tokio::test]
async fn public_policy_allows_checked_terminal_operations_and_rejects_legacy_metadata() {
    let checked = insert_synthetic_base_session_for_tests(
        "release-gate.example",
        "root",
        verified_generation(),
    )
    .unwrap();
    let guard = require_active_verified_base_session(checked.id).unwrap();
    let checked_metadata = TerminalChannelMetadata::checked(&guard, 120, 36);
    assert!(require_terminal_operation_access_with_policy(
        &checked_metadata,
        LegacyNetworkPolicy::DisabledInPublicRelease,
    )
    .is_ok());

    let legacy = insert_synthetic_base_session_for_tests(
        "legacy-release-gate.example",
        "root",
        SessionSecurityGeneration::LegacyUnverified,
    )
    .unwrap();
    let legacy_metadata = TerminalChannelMetadata::legacy(&legacy, 120, 36);
    assert!(matches!(
        require_terminal_operation_access_with_policy(
            &legacy_metadata,
            LegacyNetworkPolicy::DisabledInPublicRelease,
        ),
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(require_terminal_operation_access_with_policy(
        &legacy_metadata,
        LegacyNetworkPolicy::AllowedInternal,
    )
    .is_ok());

    let terminal_id = insert_synthetic_terminal_channel_for_tests(legacy_metadata).unwrap();
    assert!(crate::terminal::close(terminal_id).await.is_ok());
    remove_synthetic_terminal_channel_for_tests(terminal_id);
    remove_synthetic_base_session_for_tests(checked.id);
    remove_synthetic_base_session_for_tests(legacy.id);
}

#[cfg(not(feature = "legacy-network-internal"))]
#[tokio::test]
async fn release_terminal_io_rejects_legacy_but_checked_reaches_the_channel_boundary() {
    let checked = insert_synthetic_base_session_for_tests(
        "release-gate.example",
        "root",
        verified_generation(),
    )
    .unwrap();
    let guard = require_active_verified_base_session(checked.id).unwrap();
    let checked_id = insert_synthetic_terminal_channel_for_tests(TerminalChannelMetadata::checked(
        &guard, 120, 36,
    ))
    .unwrap();
    let checked_write = crate::terminal::write(checked_id, b"safe".to_vec()).await;
    let checked_resize = crate::terminal::resize(checked_id, 132, 40).await;
    assert!(!matches!(
        checked_write,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(!matches!(
        checked_resize,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(crate::terminal::close(checked_id).await.is_ok());

    let legacy = insert_synthetic_base_session_for_tests(
        "legacy-release-gate.example",
        "root",
        SessionSecurityGeneration::LegacyUnverified,
    )
    .unwrap();
    let legacy_id = insert_synthetic_terminal_channel_for_tests(TerminalChannelMetadata::legacy(
        &legacy, 120, 36,
    ))
    .unwrap();
    assert!(matches!(
        crate::terminal::write(legacy_id, b"blocked".to_vec()).await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::terminal::resize(legacy_id, 132, 40).await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(crate::terminal::close(legacy_id).await.is_ok());

    remove_synthetic_base_session_for_tests(checked.id);
    remove_synthetic_base_session_for_tests(legacy.id);
}

#[cfg(not(feature = "legacy-network-internal"))]
#[tokio::test]
async fn release_helpers_reject_before_synthetic_network_backends() {
    let legacy = insert_synthetic_base_session_for_tests(
        "release-gate.example",
        "root",
        SessionSecurityGeneration::LegacyUnverified,
    )
    .unwrap();

    assert!(matches!(
        crate::session_pool::get_or_create_base_session(
            "192.0.2.1",
            22,
            "root",
            "sensitive-password",
            "",
            "",
            false,
        )
        .await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::session_pool::resolve_base_session(legacy.id),
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::run_remote_command(&legacy, "sensitive-command").await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::terminal::open_channel(legacy.clone(), 120, 36).await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::monitor::fetch_system_stats_for_base(&legacy).await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));
    assert!(matches!(
        crate::docker::fetch_containers(&legacy).await,
        Err(OrbitCoreError::LegacyNetworkDisabled)
    ));

    remove_synthetic_base_session_for_tests(legacy.id);
}

#[test]
fn remote_exec_diagnostics_never_include_the_command_body() {
    let command = "deploy --token sensitive-command-value";
    let start = crate::remote_exec_start_diagnostic(command);
    let finish = crate::remote_exec_finish_diagnostic(command, 7, 123, 45);

    for diagnostic in [&start, &finish] {
        assert!(!diagnostic.contains(command));
        assert!(!diagnostic.contains("sensitive-command-value"));
        assert!(diagnostic.contains(&format!("command_bytes={}", command.len())));
    }
    assert!(finish.contains("exit=7"));
    assert!(finish.contains("stdout_bytes=123"));
    assert!(finish.contains("stderr_bytes=45"));
}
