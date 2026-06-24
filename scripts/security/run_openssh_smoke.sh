#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

if [[ "${ORBITTERM_RUN_OPENSSH_SMOKE:-0}" != "1" ]]; then
  printf '[SKIP] Set ORBITTERM_RUN_OPENSSH_SMOKE=1 to run the loopback OpenSSH release-candidate smoke.\n'
  exit 0
fi

require_command ssh-keygen
require_command cargo
require_command python3

SSHD_BIN="$(command -v sshd || true)"
if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
  SSHD_BIN=/usr/sbin/sshd
fi
[[ -n "$SSHD_BIN" && -x "$SSHD_BIN" ]] || \
  fail "OpenSSH smoke was requested but sshd is unavailable"

FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/OrbitTerm-openssh-smoke.XXXXXX")"
REAL_HOME="${HOME:?HOME must be set}"
CARGO_HOME_VALUE="${CARGO_HOME:-$REAL_HOME/.cargo}"
RUSTUP_HOME_VALUE="${RUSTUP_HOME:-$REAL_HOME/.rustup}"
SSHD_PID=""
PORT="$(python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
SSHD_LOG="$FIXTURE_ROOT/sshd.log"
USER_KEY="$FIXTURE_ROOT/user_key"
HOST_KEY_A="$FIXTURE_ROOT/host_key_a"
HOST_KEY_B="$FIXTURE_ROOT/host_key_b"
AUTHORIZED_KEYS="$FIXTURE_ROOT/authorized_keys"
KNOWN_HOSTS_DIR="$FIXTURE_ROOT/OrbitTerm-Security"
KNOWN_HOSTS="$KNOWN_HOSTS_DIR/known_hosts"
REVOKED_KNOWN_HOSTS="$KNOWN_HOSTS_DIR/revoked_known_hosts"
LEGACY_KNOWN_HOSTS="$KNOWN_HOSTS_DIR/legacy_no_socket_known_hosts"
FAKE_HOME="$FIXTURE_ROOT/home"
REMOTE_TEST_DIR="$FIXTURE_ROOT/remote-sftp-root"
USERNAME="$(id -un)"

stop_sshd() {
  if [[ -n "$SSHD_PID" ]]; then
    kill "$SSHD_PID" >/dev/null 2>&1 || true
    wait "$SSHD_PID" >/dev/null 2>&1 || true
    SSHD_PID=""
  fi
}

cleanup() {
  stop_sshd
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT INT TERM

generate_key() {
  local path="$1"
  ssh-keygen -q -t ed25519 -N '' -f "$path"
  chmod 600 "$path"
}

start_sshd() {
  local host_key="$1"
  local config="$FIXTURE_ROOT/sshd_config"
  stop_sshd
  cat >"$config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $host_key
AuthorizedKeysFile $AUTHORIZED_KEYS
PidFile $FIXTURE_ROOT/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin no
StrictModes no
AllowUsers $USERNAME
Subsystem sftp internal-sftp
LogLevel VERBOSE
X11Forwarding no
AllowTcpForwarding no
GatewayPorts no
PermitTunnel no
EOF
  "$SSHD_BIN" -t -f "$config"
  "$SSHD_BIN" -D -e -f "$config" >>"$SSHD_LOG" 2>&1 &
  SSHD_PID=$!

  local ready=0
  for _ in {1..100}; do
    if ! kill -0 "$SSHD_PID" >/dev/null 2>&1; then
      tail -n 50 "$SSHD_LOG" >&2 || true
      fail "ephemeral sshd exited before becoming ready"
    fi
    if grep -Fq "Server listening on 127.0.0.1 port $PORT" "$SSHD_LOG"; then
      ready=1
      break
    fi
    sleep 0.05
  done
  [[ "$ready" -eq 1 ]] || fail "timed out waiting for ephemeral sshd"
}

run_checked_scenario() {
  local scenario="$1"
  local known_hosts="$2"
  local host_public_key="$3"
  section "OpenSSH checked scenario: $scenario"
  HOME="$FAKE_HOME" \
  CARGO_HOME="$CARGO_HOME_VALUE" \
  RUSTUP_HOME="$RUSTUP_HOME_VALUE" \
  ORBITTERM_RUN_OPENSSH_SMOKE=1 \
  ORBITTERM_OPENSSH_SCENARIO="$scenario" \
  ORBITTERM_OPENSSH_FIXTURE_ROOT="$FIXTURE_ROOT" \
  ORBITTERM_OPENSSH_HOST=127.0.0.1 \
  ORBITTERM_OPENSSH_PORT="$PORT" \
  ORBITTERM_OPENSSH_USERNAME="$USERNAME" \
  ORBITTERM_OPENSSH_USER_KEY_PATH="$USER_KEY" \
  ORBITTERM_OPENSSH_KNOWN_HOSTS_PATH="$known_hosts" \
  ORBITTERM_OPENSSH_HOST_PUBLIC_KEY_PATH="$host_public_key" \
  ORBITTERM_OPENSSH_REMOTE_TEST_DIR="$REMOTE_TEST_DIR" \
  ORBITTERM_OPENSSH_SSHD_LOG_PATH="$SSHD_LOG" \
  CARGO_NET_OFFLINE=true \
    cargo test --locked --manifest-path "$ORBIT_ROOT/orbit-core/Cargo.toml" \
      security::openssh_integration_tests::openssh_checked_end_to_end_smoke \
      -- --exact --ignored --nocapture
}

run_release_legacy_no_socket() {
  section "OpenSSH Release legacy no-socket scenario"
  rm -f "$LEGACY_KNOWN_HOSTS"
  HOME="$FAKE_HOME" \
  CARGO_HOME="$CARGO_HOME_VALUE" \
  RUSTUP_HOME="$RUSTUP_HOME_VALUE" \
  ORBITTERM_RUN_OPENSSH_SMOKE=1 \
  ORBITTERM_OPENSSH_SCENARIO=legacy-no-socket \
  ORBITTERM_OPENSSH_FIXTURE_ROOT="$FIXTURE_ROOT" \
  ORBITTERM_OPENSSH_HOST=127.0.0.1 \
  ORBITTERM_OPENSSH_PORT="$PORT" \
  ORBITTERM_OPENSSH_USERNAME="$USERNAME" \
  ORBITTERM_OPENSSH_USER_KEY_PATH="$USER_KEY" \
  ORBITTERM_OPENSSH_KNOWN_HOSTS_PATH="$LEGACY_KNOWN_HOSTS" \
  ORBITTERM_OPENSSH_HOST_PUBLIC_KEY_PATH="$HOST_KEY_B.pub" \
  ORBITTERM_OPENSSH_REMOTE_TEST_DIR="$REMOTE_TEST_DIR" \
  ORBITTERM_OPENSSH_SSHD_LOG_PATH="$SSHD_LOG" \
  CARGO_NET_OFFLINE=true \
    cargo test --locked --release --manifest-path "$ORBIT_ROOT/orbit-core/Cargo.toml" \
      security::openssh_integration_tests::openssh_release_legacy_no_socket_smoke \
      -- --exact --ignored --nocapture
}

section "Generate isolated OpenSSH fixture"
mkdir -p "$KNOWN_HOSTS_DIR" "$FAKE_HOME" "$REMOTE_TEST_DIR"
chmod 700 "$FIXTURE_ROOT" "$KNOWN_HOSTS_DIR" "$FAKE_HOME" "$REMOTE_TEST_DIR"
generate_key "$USER_KEY"
generate_key "$HOST_KEY_A"
generate_key "$HOST_KEY_B"
cp "$USER_KEY.pub" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
: >"$SSHD_LOG"

start_sshd "$HOST_KEY_A"
run_checked_scenario trusted "$KNOWN_HOSTS" "$HOST_KEY_A.pub"

start_sshd "$HOST_KEY_B"
run_checked_scenario changed "$KNOWN_HOSTS" "$HOST_KEY_B.pub"

read -r host_algorithm host_key_body _ <"$HOST_KEY_B.pub"
printf '@revoked [127.0.0.1]:%s %s %s\n' "$PORT" "$host_algorithm" "$host_key_body" \
  >"$REVOKED_KNOWN_HOSTS"
chmod 600 "$REVOKED_KNOWN_HOSTS"
run_checked_scenario revoked "$REVOKED_KNOWN_HOSTS" "$HOST_KEY_B.pub"
run_release_legacy_no_socket

pass "OpenSSH loopback release-candidate smoke"
