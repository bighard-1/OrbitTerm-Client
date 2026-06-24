#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_command cargo

cd "$ORBIT_ROOT/orbit-core"
export CARGO_NET_OFFLINE=true

section "Rust formatting"
cargo fmt --check

section "Rust tests (Debug)"
cargo test --locked --all-targets

section "Rust tests and legacy fail-closed harness (Release)"
cargo test --locked --release --all-targets
cargo test --locked --release --lib \
  c_ffi::tests::release_c_abi_legacy_symbols_fail_before_pointer_parsing_or_lookup -- --exact

section "Internal legacy policy compile smoke"
cargo test --locked --release --lib --features legacy-network-internal \
  legacy_network_tests::policy_is_compile_time_only_and_public_release_is_fail_closed -- --exact
cargo test --locked --lib --features legacy-network-internal \
  security::insecure_legacy_host_key_handler::tests::internal_feature_exposes_a_distinct_legacy_handler_type -- --exact

section "Rust clippy"
cargo clippy --locked --all-targets --all-features -- -D warnings

section "Rust builds"
cargo build --locked
cargo build --locked --release

section "Whitespace validation"
git -C "$ORBIT_ROOT" diff --check

pass "Rust release gates"
