#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: sudo $0 --host IPV4 --port PORT --duration-seconds 1..120 [--terminate-existing]" >&2
}

host=""
port=""
duration=""
terminate_existing=false
while (($#)); do
    case "$1" in
        --host) host="${2:-}"; shift 2 ;;
        --port) port="${2:-}"; shift 2 ;;
        --duration-seconds) duration="${2:-}"; shift 2 ;;
        --terminate-existing) terminate_existing=true; shift ;;
        *) usage; exit 2 ;;
    esac
done

if ((EUID != 0)) ||
    [[ ! "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
    [[ ! "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)) ||
    [[ ! "$duration" =~ ^[0-9]+$ ]] || ((10#$duration < 1 || 10#$duration > 120)); then
    usage
    exit 2
fi

IFS=. read -r octet1 octet2 octet3 octet4 <<<"$host"
for octet in "$octet1" "$octet2" "$octet3" "$octet4"; do
    if ((10#$octet > 255)); then
        usage
        exit 2
    fi
done

iptables_bin="$(command -v iptables)"
systemctl_bin="$(command -v systemctl)"
systemd_run_bin="$(command -v systemd-run)"
tag="orbitterm-rdp-fault-$$"
cleanup_unit="${tag}-cleanup"
rule=(
    OUTPUT -d "${host}/32" -p tcp --dport "$port"
    -m comment --comment "$tag"
    -j REJECT --reject-with tcp-reset
)

cleanup() {
    set +e
    if "$iptables_bin" -C "${rule[@]}" >/dev/null 2>&1; then
        "$iptables_bin" -D "${rule[@]}"
    fi
    "$systemctl_bin" stop "${cleanup_unit}.timer" "${cleanup_unit}.service" \
        >/dev/null 2>&1 || true
    "$systemctl_bin" reset-failed "${cleanup_unit}.service" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

if "$iptables_bin" -S OUTPUT | grep -F -- "-d ${host}/32" | grep -F -- "--dport ${port}" >/dev/null; then
    echo "Refusing to inject: an OUTPUT rule already targets ${host}:${port}." >&2
    exit 3
fi

# Register an independent system timer before adding the rule. It removes this
# exact tagged rule even if the invoking shell, SSH connection or test runner
# disappears unexpectedly. The local trap provides the normal fast cleanup.
"$systemd_run_bin" --quiet --unit "$cleanup_unit" --on-active="${duration}s" \
    "$iptables_bin" -D "${rule[@]}"
# UFW's OUTPUT chain can accept NEW traffic before appended rules are reached.
# Insert this narrowly scoped rule first so reconnect attempts are also covered;
# cleanup still deletes only the exact tagged rule.
"$iptables_bin" -I "${rule[@]}"

if $terminate_existing; then
    ss -K dst "$host" dport = "$port" >/dev/null 2>&1 || true
fi

echo "ACTIVE ${host}:${port} duration=${duration}s tag=${tag}"
sleep "$duration"
echo "CLEANED ${host}:${port} tag=${tag}"
