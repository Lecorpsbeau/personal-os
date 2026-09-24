#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/personal-os-service-test.XXXXXX")"
FAILURES=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

pid_alive() {
    local pid="$1"
    local state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v plutil >/dev/null 2>&1; then
    printf '%s\n' 'Service tests skipped: macOS plutil is unavailable.'
    exit 0
fi

TEST_HOME="$TEST_ROOT/home"
LAUNCH_AGENTS="$TEST_HOME/Library/LaunchAgents"
SUPPORT_DIR="$TEST_HOME/Library/Application Support/PersonalOS"
LOG_DIR="$TEST_HOME/Library/Logs/PersonalOS"
DATABASE="$SUPPORT_DIR/mac_detective.sqlite"
RUNTIME_STATUS="$SUPPORT_DIR/.mac-detective-runtime-status.json"
SERVICE_LABEL="com.personal-os.test.mac-detective"
FAKE_BIN_DIR="$TEST_ROOT/bin"
FAKE_STATE_DIR="$TEST_ROOT/launchctl-state"
FAKE_LAUNCHCTL="$TEST_ROOT/launchctl"
FAKE_SWIFT_DIR="$TEST_ROOT/swift-bin"
mkdir -p "$LAUNCH_AGENTS" "$SUPPORT_DIR" "$LOG_DIR" "$FAKE_BIN_DIR" "$FAKE_STATE_DIR" "$FAKE_SWIFT_DIR"

cat > "$FAKE_LAUNCHCTL" <<'EOF'
#!/usr/bin/env bash
set -eu
STATE_DIR="${FAKE_STATE_DIR:?}"
case "${1:-}" in
    print)
        if [[ -f "$STATE_DIR/loaded" ]]; then
            if [[ -f "$STATE_DIR/print-output" ]]; then
                cat "$STATE_DIR/print-output"
            else
                printf '%s\n' 'state = running'
            fi
            exit 0
        fi
        exit 113
        ;;
    bootstrap)
        touch "$STATE_DIR/loaded"
        exit 0
        ;;
    bootout)
        rm -f "$STATE_DIR/loaded"
        exit 0
        ;;
    enable)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FAKE_LAUNCHCTL"

cat > "$FAKE_SWIFT_DIR/swift" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$*" == *--show-bin-path* ]]; then
    printf '%s\n' "$FAKE_BIN_DIR"
fi
exit 0
EOF
chmod +x "$FAKE_SWIFT_DIR/swift"

cat > "$FAKE_BIN_DIR/mac-detective" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$$" > "$FAKE_STATE_DIR/mac-started.pid"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/mac-detective"

cat > "$FAKE_BIN_DIR/PersonalOSDashboard" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$$" > "$FAKE_STATE_DIR/dashboard.pid"
trap 'exit 0' TERM INT HUP
while :; do sleep 0.1; done
EOF
chmod +x "$FAKE_BIN_DIR/PersonalOSDashboard"

export HOME="$TEST_HOME"
export PATH="$FAKE_SWIFT_DIR:$PATH"
export PERSONAL_OS_SERVICE_LABEL="$SERVICE_LABEL"
export PERSONAL_OS_LAUNCHCTL_BIN="$FAKE_LAUNCHCTL"
export PERSONAL_OS_LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS"
export PERSONAL_OS_SERVICE_SUPPORT_DIR="$SUPPORT_DIR"
export PERSONAL_OS_LOG_DIR="$LOG_DIR"
export MAC_DETECTIVE_DATABASE="$DATABASE"
export MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS"
export MAC_DETECTIVE_FS_USAGE=0
export FAKE_BIN_DIR
export FAKE_STATE_DIR

SERVICE_ENV=(
    HOME="$TEST_HOME"
    PATH="$PATH"
    PERSONAL_OS_SERVICE_LABEL="$SERVICE_LABEL"
    PERSONAL_OS_LAUNCHCTL_BIN="$FAKE_LAUNCHCTL"
    PERSONAL_OS_LAUNCH_AGENTS_DIR="$LAUNCH_AGENTS"
    PERSONAL_OS_SERVICE_SUPPORT_DIR="$SUPPORT_DIR"
    PERSONAL_OS_LOG_DIR="$LOG_DIR"
    MAC_DETECTIVE_DATABASE="$DATABASE"
    MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS"
    MAC_DETECTIVE_FS_USAGE=0
    PERSONAL_OS_SWIFT_BIN=swift
    FAKE_BIN_DIR="$FAKE_BIN_DIR"
    FAKE_STATE_DIR="$FAKE_STATE_DIR"
)

run_install() {
    env "${SERVICE_ENV[@]}" "$ROOT_DIR/scripts/install-personal-os-service.sh"
}

run_uninstall() {
    env "${SERVICE_ENV[@]}" "$ROOT_DIR/scripts/uninstall-personal-os-service.sh"
}

run_status() {
    env "${SERVICE_ENV[@]}" "$ROOT_DIR/scripts/status-personal-os-service.sh"
}

PLIST="$LAUNCH_AGENTS/$SERVICE_LABEL.plist"

if ! run_install > "$TEST_ROOT/install-1.log" 2>&1; then
    fail "first installation failed"
fi
if ! run_install > "$TEST_ROOT/install-2.log" 2>&1; then
    fail "second installation failed"
fi

[[ -f "$PLIST" ]] || fail "LaunchAgent plist was not installed"
if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
    fail "installed plist is invalid"
fi
[[ "$(plutil -extract Label raw -o - "$PLIST")" == "$SERVICE_LABEL" ]] || fail "unexpected service label"
[[ "$(plutil -extract RunAtLoad raw -o - "$PLIST")" == "true" ]] || fail "RunAtLoad is not enabled"
[[ "$(plutil -extract KeepAlive.SuccessfulExit raw -o - "$PLIST")" == "false" ]] || fail "KeepAlive policy is incorrect"
[[ "$(plutil -extract StandardOutPath raw -o - "$PLIST")" == "$LOG_DIR/mac-detective.stdout.log" ]] || fail "stdout path is incorrect"
[[ "$(plutil -extract StandardErrorPath raw -o - "$PLIST")" == "$LOG_DIR/mac-detective.stderr.log" ]] || fail "stderr path is incorrect"
[[ "$(plutil -extract ProgramArguments.0 raw -o - "$PLIST")" == "$SUPPORT_DIR/bin/mac-detective" ]] || fail "service binary is not in stable support directory"
[[ "$(plutil -extract ProgramArguments json -o - "$PLIST" | grep -o 'mac-detective' | wc -l | tr -d '[:space:]')" == "1" ]] || fail "ProgramArguments contains more than the executable"
if grep -q '/Users/' "$ROOT_DIR/deploy/com.personal-os.mac-detective.plist"; then
    fail "plist template contains a hardcoded user path"
fi
printf 'fixture' > "$DATABASE"
printf '{"version":1,"state":"running","cycles_executed":1,"last_successful_persistence_at":"2026-01-01T00:00:00Z"}' > "$RUNTIME_STATUS"
printf 'stdout\n' > "$LOG_DIR/mac-detective.stdout.log"
printf 'stderr\n' > "$LOG_DIR/mac-detective.stderr.log"
printf 'pid = %s;\nstate = running\nlast exit code = 0;\n' "$$" > "$FAKE_STATE_DIR/print-output"
touch "$FAKE_STATE_DIR/loaded"

# A loaded service must make the M011 launcher start only the Dashboard.
env "${SERVICE_ENV[@]}" \
    PERSONAL_OS_SERVICE_PLIST="$PLIST" \
    MAC_DETECTIVE_BIN="$FAKE_BIN_DIR/mac-detective" \
    DASHBOARD_BIN="$FAKE_BIN_DIR/PersonalOSDashboard" \
    "$ROOT_DIR/scripts/start-personal-os.sh" > "$TEST_ROOT/service-launcher.log" 2>&1 &
LAUNCHER_PID=$!
for _ in $(seq 1 50); do
    [[ -s "$FAKE_STATE_DIR/dashboard.pid" ]] && break
    sleep 0.1
done
if [[ -s "$FAKE_STATE_DIR/dashboard.pid" ]]; then
    if [[ -e "$FAKE_STATE_DIR/mac-started.pid" ]]; then
        fail "M011 launcher started a second mac-detective instance"
    fi
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    if wait "$LAUNCHER_PID"; then
        launcher_code=0
    else
        launcher_code=$?
    fi
    [[ "$launcher_code" -eq 143 ]] || fail "service-mode launcher returned $launcher_code"
    if pid_alive "$(<"$FAKE_STATE_DIR/dashboard.pid")"; then
        fail "service-mode Dashboard was not cleaned"
    fi
else
    fail "M011 launcher did not start Dashboard in service mode"
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    wait "$LAUNCHER_PID" 2>/dev/null || true
fi
rm -f "$FAKE_STATE_DIR/dashboard.pid" "$FAKE_STATE_DIR/mac-started.pid"

STATUS_OUTPUT="$(run_status)"
printf '%s\n' "$STATUS_OUTPUT" | grep -q '^service_state=RUNNING$' || fail "status did not report RUNNING"
printf '%s\n' "$STATUS_OUTPUT" | grep -q "^pid=$$\$" || fail "status did not detect PID"
printf '%s\n' "$STATUS_OUTPUT" | grep -q "^database=$DATABASE$" || fail "status database path mismatch"
printf 'pid = %s;\nstate = running\nlast exit code = (never exited);\n' "$$" > "$FAKE_STATE_DIR/print-output"
NEVER_EXITED_OUTPUT="$(run_status)"
printf '%s\n' "$NEVER_EXITED_OUTPUT" | grep -q '^service_state=RUNNING$' || fail "never-exited launchd state was treated as failure"

printf 'state = running\n' > "$FAKE_STATE_DIR/print-output"
touch -t 200001010000 "$RUNTIME_STATUS"
STALE_OUTPUT="$(run_status)"
printf '%s\n' "$STALE_OUTPUT" | grep -q '^service_state=STALE$' || fail "status did not report STALE"

printf 'state = waiting\n' > "$FAKE_STATE_DIR/print-output"
touch "$RUNTIME_STATUS"
NOT_RUNNING_OUTPUT="$(run_status)"
printf '%s\n' "$NOT_RUNNING_OUTPUT" | grep -q '^service_state=LOADED_NOT_RUNNING$' || fail "loaded service without PID was not explicit"

rm -f "$PLIST" "$FAKE_STATE_DIR/loaded"
NOT_INSTALLED_OUTPUT="$(run_status)"
printf '%s\n' "$NOT_INSTALLED_OUTPUT" | grep -q '^service_state=NOT_INSTALLED$' || fail "missing service was not explicit"

# Reinstall for uninstall safety checks.
if ! run_install > "$TEST_ROOT/install-3.log" 2>&1; then
    fail "reinstallation before uninstall failed"
fi
printf 'persistent-data' > "$DATABASE"
printf 'persistent-log' > "$LOG_DIR/mac-detective.stdout.log"
if ! run_uninstall > "$TEST_ROOT/uninstall-1.log" 2>&1; then
    fail "first uninstall failed"
fi
if ! run_uninstall > "$TEST_ROOT/uninstall-2.log" 2>&1; then
    fail "second uninstall failed"
fi
[[ ! -e "$PLIST" ]] || fail "uninstall left the plist behind"
[[ -f "$DATABASE" ]] || fail "uninstall deleted SQLite data"
[[ -f "$LOG_DIR/mac-detective.stdout.log" ]] || fail "uninstall deleted user logs"

printf 'log-line-that-should-rotate\n' > "$LOG_DIR/mac-detective.stdout.log"
env "${SERVICE_ENV[@]}" PERSONAL_OS_LOG_MAX_BYTES=1 \
    "$ROOT_DIR/scripts/rotate-personal-os-logs.sh" rotate >/dev/null
[[ -f "$LOG_DIR/mac-detective.stdout.log.1" ]] || fail "log rotation did not create a backup"
[[ ! -s "$LOG_DIR/mac-detective.stdout.log" ]] || fail "log rotation did not truncate the active log"

if (( FAILURES == 0 )); then
    printf '%s\n' 'Service tests passed.'
else
    printf '%s\n' "$FAILURES service test(s) failed." >&2
    exit 1
fi
