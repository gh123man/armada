#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY="$ROOT/system_files/usr/libexec/armada/suspend-wake-policy"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

assert_eq() {
    local actual=$1 expected=$2
    if [[ "$actual" != "$expected" ]]; then
        printf 'assertion failed: expected <%s>, got <%s>\n' "$expected" "$actual" >&2
        exit 1
    fi
}

assert_missing() {
    if [[ -e "$1" ]]; then
        printf 'assertion failed: expected %s to be absent\n' "$1" >&2
        exit 1
    fi
}

mkdir -p "$tmp/power/usb" "$tmp/run"
printf 'USB\n' >"$tmp/power/usb/type"
printf '0\n' >"$tmp/power/usb/online"
printf '42\n' >"$tmp/wakeup_count"
: >"$tmp/power_state"
printf ' 21: 4 0 0 0 pmic_arb 1303088 Edge pmic_pwrkey\n 230: 1 0 0 0 ipcc 196608 Edge glink-smem\n' \
    >"$tmp/interrupts"

cat >"$tmp/device-env" <<'EOF'
#!/bin/bash
printf 'ARMADA_SUSPEND_MODE=mem\n'
printf 'ARMADA_WAKE_POLICY=pmic-glink\n'
EOF
chmod +x "$tmp/device-env"

cat >"$tmp/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
chmod +x "$tmp/timeout"

run_policy() {
    ARMADA_DEVICE_ENV_BIN="$tmp/device-env" \
    ARMADA_POWER_SUPPLY_ROOT="$tmp/power" \
    ARMADA_PM_WAKEUP_IRQ_PATH="$tmp/pm_wakeup_irq" \
    ARMADA_INTERRUPTS_PATH="$tmp/interrupts" \
    ARMADA_WAKEUP_COUNT_PATH="$tmp/wakeup_count" \
    ARMADA_POWER_STATE_PATH="$tmp/power_state" \
    ARMADA_WAKE_POLICY_RUN_DIR="$tmp/run" \
    ARMADA_WAKE_POLICY_CHARGER_POLLS=0 \
    ARMADA_WAKE_POLICY_MAX_BACKGROUND_WAKES=1 \
    ARMADA_WAKE_POLICY_LOG_BIN="${ARMADA_WAKE_POLICY_LOG_BIN:-/bin/true}" \
    ARMADA_WAKE_POLICY_TIMEOUT_BIN="$tmp/timeout" \
        "$POLICY" "$@"
}

run_policy pre suspend
assert_eq "$(<"$tmp/run/external-power-online")" 0
assert_eq "$(<"$tmp/run/power-key-interrupt-count")" 4

# A kernel without CONFIG_PM_SLEEP_DEBUG has no pm_wakeup_irq attribute and
# must fail open instead of attempting a resuspend.
assert_eq "$(run_policy classify)" missing-irq

printf '230\n' >"$tmp/pm_wakeup_irq"
assert_eq "$(run_policy classify)" background-glink

printf '1\n' >"$tmp/power/usb/online"
assert_eq "$(run_policy classify)" charger-attach

printf '0\n' >"$tmp/power/usb/online"
# A direct power-key IRQ wins even if IPCC also reports queued GLINK traffic.
printf ' 21: 6 0 0 0 pmic_arb 1303088 Edge pmic_pwrkey\n 230: 2 0 0 0 ipcc 196608 Edge glink-smem\n' \
    >"$tmp/interrupts"
printf '230\n' >"$tmp/pm_wakeup_irq"
assert_eq "$(run_policy classify)" power-key

# Refresh the physical-key snapshot before testing an unrelated wake reason.
run_policy pre suspend
printf '999\n' >"$tmp/pm_wakeup_irq"
assert_eq "$(run_policy classify)" unknown

# Track power changes during one hidden resume transaction. Starting plugged,
# unplug remains a background wake but updates the last-observed state; the
# following replug is then a real 0-to-1 charger attach and must resume.
printf '1\n' >"$tmp/power/usb/online"
run_policy pre suspend
printf '0\n' >"$tmp/power/usb/online"
printf '230\n' >"$tmp/pm_wakeup_irq"
assert_eq "$(run_policy classify)" background-glink
assert_eq "$(<"$tmp/run/external-power-online")" 0
printf '1\n' >"$tmp/power/usb/online"
assert_eq "$(run_policy classify)" charger-attach

# Restore the disconnected state for the resuspend tests below.
printf '0\n' >"$tmp/power/usb/online"

# The kernel accounting fix exposes the pending IPCC child on resume.
run_policy pre suspend
printf '230\n' >"$tmp/pm_wakeup_irq"
run_policy post suspend
assert_eq "$(<"$tmp/power_state")" mem
assert_missing "$tmp/run/external-power-online"
assert_missing "$tmp/run/power-key-interrupt-count"

# A wake arriving between wakeup_count and power/state returns -EBUSY. Keep an
# already-classified GLINK wake inside the suspend transaction and retry it.
cat >"$tmp/suspend-once-busy" <<'EOF'
#!/bin/bash
dir="$(dirname -- "$0")"
attempts_file="$dir/suspend-attempts"
power_state="$dir/power_state"
attempts=0
[[ ! -r "$attempts_file" ]] || read -r attempts <"$attempts_file"
attempts=$((attempts + 1))
printf '%s\n' "$attempts" >"$attempts_file"
(( attempts > 1 )) || exit 16
printf 'mem\n' >"$power_state"
EOF
chmod +x "$tmp/suspend-once-busy"

run_policy pre suspend
printf '230\n' >"$tmp/pm_wakeup_irq"
ARMADA_DEVICE_ENV_BIN="$tmp/device-env" \
ARMADA_POWER_SUPPLY_ROOT="$tmp/power" \
ARMADA_PM_WAKEUP_IRQ_PATH="$tmp/pm_wakeup_irq" \
ARMADA_INTERRUPTS_PATH="$tmp/interrupts" \
ARMADA_WAKEUP_COUNT_PATH="$tmp/wakeup_count" \
ARMADA_POWER_STATE_PATH="$tmp/power_state" \
ARMADA_WAKE_POLICY_RUN_DIR="$tmp/run" \
ARMADA_WAKE_POLICY_CHARGER_POLLS=0 \
ARMADA_WAKE_POLICY_MAX_BACKGROUND_WAKES=1 \
ARMADA_WAKE_POLICY_MAX_RESUSPEND_RETRIES=2 \
ARMADA_WAKE_POLICY_RESUSPEND_RETRY_INTERVAL=0 \
ARMADA_WAKE_POLICY_LOG_BIN=/bin/true \
ARMADA_WAKE_POLICY_TIMEOUT_BIN="$tmp/timeout" \
ARMADA_WAKE_POLICY_SUSPEND_BIN="$tmp/suspend-once-busy" \
    "$POLICY" post suspend
assert_eq "$(<"$tmp/suspend-attempts")" 2
assert_eq "$(<"$tmp/power_state")" mem

printf 'suspend wake policy test passed\n'
