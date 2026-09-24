#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/personal-os-launcher-test.XXXXXX")"
FAILURES=0
LAUNCHER_PID=""

cleanup() {
    if [[ -n "$LAUNCHER_PID" ]] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
        kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
        wait "$LAUNCHER_PID" 2>/dev/null || true
    fi
    for pid_file in "$TEST_ROOT"/state/*.pid; do
        if [[ -f "$pid_file" ]]; then
            pid="$(<"$pid_file")"
            if process_is_alive "$pid"; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        fi
    done
    sleep 0.1
    for pid_file in "$TEST_ROOT"/state/*.pid; do
        if [[ -f "$pid_file" ]]; then
            pid="$(<"$pid_file")"
            if process_is_alive "$pid"; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    done
    if [[ "${KEEP_TEST_ROOT:-0}" == "1" ]]; then
        printf 'Launcher test artifacts: %s\n' "$TEST_ROOT" >&2
    else
        rm -rf "$TEST_ROOT"
    fi
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

process_is_alive() {
    local pid="$1"
    local state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

wait_for_file() {
    local path="$1"
    local attempts=0
    while [[ ! -s "$path" && "$attempts" -lt 50 ]]; do
        sleep 0.1
        attempts=$((attempts + 1))
    done
    [[ -s "$path" ]]
}

make_fake_binary() {
    local path="$1"
    local kind="$2"
    cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -eu
FAKE_KIND="__KIND__"
printf '%s\n' "$$" > "$FAKE_STATE_DIR/$FAKE_KIND.pid"
if [[ "$FAKE_KIND" == "mac-detective" ]]; then
    sleep 30 &
    printf '%s\n' "$!" > "$FAKE_STATE_DIR/$FAKE_KIND.child.pid"
    printf '%s\n' "$MAC_DETECTIVE_DATABASE" > "$FAKE_STATE_DIR/database.path"
    printf '%s\n' "$MAC_DETECTIVE_RUNTIME_STATUS" > "$FAKE_STATE_DIR/status.path"
    printf '%s\n' "${MAC_DETECTIVE_FS_USAGE:-}" > "$FAKE_STATE_DIR/fs_usage.mode"
    if [[ "${FAKE_MAC_MODE:-run}" == "fail" ]]; then
        exit 42
    fi
    if [[ "${FAKE_MAC_MODE:-run}" == "bad-status" ]]; then
        printf '{not-json' > "$MAC_DETECTIVE_RUNTIME_STATUS"
        trap 'exit 0' TERM INT HUP
        while :; do sleep 0.1; done
    fi
    printf 'fixture' > "$MAC_DETECTIVE_DATABASE"
    printf '{"version":1,"state":"running","cycles_executed":1,"last_successful_persistence_at":"2026-01-01T00:00:00Z"}' > "$MAC_DETECTIVE_RUNTIME_STATUS"
else
    if [[ "${FAKE_DASHBOARD_MODE:-run}" == "fail" ]]; then
        exit 43
    fi
fi
trap 'exit 0' TERM INT
while :; do
    sleep 0.1
done
EOF
    sed -i.bak "s/__KIND__/$kind/g" "$path"
    rm -f "$path.bak"
    chmod +x "$path"
}

STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR"
MAC_FAKE="$TEST_ROOT/mac-detective"
DASHBOARD_FAKE="$TEST_ROOT/dashboard"
make_fake_binary "$MAC_FAKE" mac-detective
make_fake_binary "$DASHBOARD_FAKE" dashboard

run_launcher() {
    local mac_mode="${1:-run}"
    local dashboard_mode="${2:-run}"
    env \
        PERSONAL_OS_RUNTIME_DIR="$TEST_ROOT/runtime" \
        MAC_DETECTIVE_DATABASE="$TEST_ROOT/data/mac_detective.sqlite" \
        MAC_DETECTIVE_RUNTIME_STATUS="$TEST_ROOT/data/runtime-status.json" \
        MAC_DETECTIVE_BIN="$MAC_FAKE" \
        DASHBOARD_BIN="$DASHBOARD_FAKE" \
        FAKE_STATE_DIR="$STATE_DIR" \
        FAKE_MAC_MODE="$mac_mode" \
        FAKE_DASHBOARD_MODE="$dashboard_mode" \
        PERSONAL_OS_START_TIMEOUT=3 \
        PERSONAL_OS_SHUTDOWN_TIMEOUT=2 \
        "$ROOT_DIR/scripts/start-personal-os.sh"
}

start_in_background() {
    local mac_mode="${1:-run}"
    local dashboard_mode="${2:-run}"
    (
        exec env \
            PERSONAL_OS_RUNTIME_DIR="$TEST_ROOT/runtime" \
            MAC_DETECTIVE_DATABASE="$TEST_ROOT/data/mac_detective.sqlite" \
            MAC_DETECTIVE_RUNTIME_STATUS="$TEST_ROOT/data/runtime-status.json" \
            MAC_DETECTIVE_BIN="$MAC_FAKE" \
            DASHBOARD_BIN="$DASHBOARD_FAKE" \
            FAKE_STATE_DIR="$STATE_DIR" \
            FAKE_MAC_MODE="$mac_mode" \
            FAKE_DASHBOARD_MODE="$dashboard_mode" \
            PERSONAL_OS_START_TIMEOUT=3 \
            PERSONAL_OS_SHUTDOWN_TIMEOUT=2 \
            "$ROOT_DIR/scripts/start-personal-os.sh"
    ) > "$TEST_ROOT/current.log" 2>&1 &
    LAUNCHER_PID=$!
}

# Paths are forwarded consistently and both children are cleaned on shutdown.
start_in_background
if wait_for_file "$STATE_DIR/dashboard.pid"; then
    if ! grep -Fxq "$TEST_ROOT/data/mac_detective.sqlite" "$STATE_DIR/database.path"; then
        fail "database path was not forwarded"
    fi
    if ! grep -Fxq "$TEST_ROOT/data/runtime-status.json" "$STATE_DIR/status.path"; then
        fail "runtime status path was not forwarded"
    fi
    if ! grep -Fxq "0" "$STATE_DIR/fs_usage.mode"; then
        fail "fs_usage was not disabled by default"
    fi
    sleep 0.5
    kill -TERM "$LAUNCHER_PID"
    if wait "$LAUNCHER_PID"; then
        launcher_code=0
    else
        launcher_code=$?
    fi
    [[ "$launcher_code" -eq 143 ]] || fail "shutdown returned $launcher_code instead of 143"
    for child in "$STATE_DIR/mac-detective.pid" "$STATE_DIR/dashboard.pid" "$STATE_DIR/mac-detective.child.pid"; do
        if [[ -f "$child" ]] && process_is_alive "$(<"$child")"; then
            fail "child was not cleaned: $child"
        fi
    done
    [[ ! -d "$TEST_ROOT/runtime/launcher.lock" ]] || fail "launcher lock was not removed"
else
    fail "dashboard did not start"
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    wait "$LAUNCHER_PID" 2>/dev/null || true
fi
LAUNCHER_PID=""

# A live lock prevents a second instance.
rm -f "$STATE_DIR"/*.pid "$STATE_DIR"/*.path
start_in_background
if wait_for_file "$STATE_DIR/dashboard.pid"; then
    if run_launcher > "$TEST_ROOT/second-instance.log" 2>&1; then
        fail "second launcher was allowed to start"
    fi
    grep -q 'already running' "$TEST_ROOT/second-instance.log" || \
        fail "second launcher did not report the active lock"
    kill -TERM "$LAUNCHER_PID"
    wait "$LAUNCHER_PID" 2>/dev/null || true
else
    fail "first launcher did not become ready for lock test"
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    wait "$LAUNCHER_PID" 2>/dev/null || true
fi
LAUNCHER_PID=""

# A stale lock with an invalid owner is recovered.
rm -rf "$TEST_ROOT/runtime" "$STATE_DIR"/*.pid "$STATE_DIR"/*.path
mkdir -p "$TEST_ROOT/runtime/launcher.lock"
printf '%s\n' 0 > "$TEST_ROOT/runtime/launcher.lock/pid"
start_in_background
if wait_for_file "$STATE_DIR/dashboard.pid"; then
    kill -TERM "$LAUNCHER_PID"
    wait "$LAUNCHER_PID" 2>/dev/null || true
else
    fail "stale launcher lock was not recovered"
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    wait "$LAUNCHER_PID" 2>/dev/null || true
fi
LAUNCHER_PID=""

# A mac-detective failure before readiness is surfaced and does not start the UI.
rm -rf "$TEST_ROOT/runtime" "$STATE_DIR"/*.pid "$STATE_DIR"/*.path
if run_launcher fail > "$TEST_ROOT/mac-failure.log" 2>&1; then
    fail "premature mac-detective exit returned success"
fi
grep -q 'exited before readiness' "$TEST_ROOT/mac-failure.log" || \
    fail "premature mac-detective exit was not reported"
[[ ! -f "$STATE_DIR/dashboard.pid" ]] || fail "dashboard started after mac-detective failure"

# Malformed status data is not accepted as readiness.
rm -rf "$TEST_ROOT/runtime" "$STATE_DIR"/*.pid "$STATE_DIR"/*.path
if run_launcher bad-status > "$TEST_ROOT/status-failure.log" 2>&1; then
    fail "malformed runtime status returned success"
fi
grep -q 'Timed out waiting' "$TEST_ROOT/status-failure.log" || \
    fail "malformed runtime status was not rejected"
[[ ! -f "$STATE_DIR/dashboard.pid" ]] || fail "dashboard started for malformed status"

# A dashboard failure terminates mac-detective and returns a failure code.
rm -rf "$TEST_ROOT/runtime" "$STATE_DIR"/*.pid "$STATE_DIR"/*.path
if run_launcher run fail > "$TEST_ROOT/dashboard-failure.log" 2>&1; then
    fail "dashboard failure returned success"
fi
grep -q 'Dashboard stopped unexpectedly' "$TEST_ROOT/dashboard-failure.log" || \
    fail "dashboard failure was not reported"
if [[ -f "$STATE_DIR/mac-detective.pid" ]] && process_is_alive "$(<"$STATE_DIR/mac-detective.pid")"; then
    fail "mac-detective survived dashboard failure"
fi

if (( FAILURES == 0 )); then
    printf '%s\n' 'Launcher tests passed.'
else
    printf '%s\n' "$FAILURES launcher test(s) failed." >&2
    exit 1
fi
