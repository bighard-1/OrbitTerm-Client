#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
linux_root="$(cd -- "${script_dir}/.." && pwd)"
evidence_dir="${ORBITTERM_SYNC_EVIDENCE_DIR:-${linux_root}/evidence}"

source "$HOME/.cargo/env" 2>/dev/null || true
umask 077

run_exact() {
  local package="$1"
  local test_name="$2"
  cargo test --locked --manifest-path "$linux_root/Cargo.toml" \
    -p "$package" "$test_name" -- --exact
}

run_exact orbit-linux-platform sync_operations::tests::queue_recovers_after_reopen_without_persisting_auth_or_plaintext_secrets
run_exact orbit-linux-platform sync_operations::tests::malformed_persistent_queue_fails_closed_without_overwrite
run_exact orbit-linux-platform sync_operations::tests::persistent_queue_refuses_symbolic_links
run_exact orbit-linux-sync tests::queued_upload_replay_sends_the_exact_same_idempotent_body
run_exact orbit-linux-sync tests::server_5xx_is_bounded_and_classified_for_queue_retry
run_exact orbit-linux-sync tests::refused_connection_is_classified_for_queue_retry
run_exact orbit-linux-sync tests::refreshes_once_after_unauthorized_then_retries_pull
run_exact orbit-linux-sync tests::queued_asset_stays_deferred_without_decrypting_or_advancing
run_exact orbit-linux-sync tests::purged_tombstone_is_satisfied_only_when_local_asset_is_absent
run_exact orbit-linux-sync tests::recognizes_known_account_scoped_auxiliary_records_without_blocking_assets
run_exact orbit-linux-sync tests::malformed_or_unknown_unbound_records_remain_fail_closed
run_exact orbitterm-linux sync_scheduler::tests::background_work_is_single_flight
run_exact orbitterm-linux sync_scheduler::tests::open_dialog_suppresses_background_work_until_closed
run_exact orbitterm-linux sync_session::tests::account_switch_replaces_the_in_memory_unlock
run_exact orbitterm-linux sync_session::tests::unlock_expires_and_explicit_lock_clears_account_scope
run_exact orbitterm-linux sync_session::tests::notification_keys_are_deduplicated_until_health_recovers

mkdir -p "$evidence_dir"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$evidence_dir/linux-sync-fault-matrix-${timestamp}.txt"
platform="$(uname -srm)"
rust_version="$(rustc --version)"
platform_source_sha="$(sha256sum "$linux_root/crates/orbit-linux-platform/src/sync_operations.rs" | awk '{print $1}')"
sync_source_sha="$(sha256sum "$linux_root/crates/orbit-linux-sync/src/lib.rs" | awk '{print $1}')"
scheduler_source_sha="$(sha256sum "$linux_root/crates/orbit-linux-app/src/sync_scheduler.rs" | awk '{print $1}')"
session_source_sha="$(sha256sum "$linux_root/crates/orbit-linux-app/src/sync_session.rs" | awk '{print $1}')"

{
  echo "OrbitTerm Linux Sync Fault Matrix Evidence v1"
  echo "generated_utc=${timestamp}"
  echo "platform=${platform}"
  echo "rust=${rust_version}"
  echo "sync_operations_source_sha256=${platform_source_sha}"
  echo "sync_protocol_source_sha256=${sync_source_sha}"
  echo "sync_scheduler_source_sha256=${scheduler_source_sha}"
  echo "sync_session_source_sha256=${session_source_sha}"
  echo "F01_restart_recovery_and_secret_exclusion=PASS"
  echo "F02_malformed_queue_fail_closed=PASS"
  echo "F03_symlink_refusal=PASS"
  echo "F04_exact_upload_replay=PASS"
  echo "F05_bounded_5xx_retry=PASS"
  echo "F06_connection_refusal_classification=PASS"
  echo "F07_401_refresh_and_retry=PASS"
  echo "F08_pending_asset_blocks_cursor=PASS"
  echo "F09_scheduler_single_flight_and_dialog_exclusion=PASS"
  echo "F10_master_unlock_account_scope_expiry_and_notification_dedup=PASS"
  echo "F11_purged_tombstone_cursor_safety=PASS"
  echo "F12_auxiliary_record_compatibility_and_fail_closed=PASS"
  echo "real_account_matrix=NOT_RUN"
  echo "real_account_reason=separate real-account matrix intentionally not executed by this fault harness"
} >"$report"

chmod 600 "$report"
echo "Evidence: $report"
sha256sum "$report"
