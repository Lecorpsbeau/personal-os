#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/personal-os-launchd-smoke.XXXXXX")"
SERVICE_LABEL="${PERSONAL_OS_SMOKE_LABEL:-com.personal-os.smoke.$$}"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$SERVICE_LABEL"
AGENTS="$SMOKE_ROOT/LaunchAgents"
SUPPORT="$SMOKE_ROOT/Application Support/PersonalOS"
LOGS="$SMOKE_ROOT/Logs/PersonalOS"
DATABASE="$SUPPORT/mac_detective.sqlite"
RUNTIME_STATUS="$SUPPORT/.mac-detective-runtime-status.json"

cleanup() {
    launchctl bootout "$TARGET" >/dev/null 2>&1 || true
    rm -f "$AGENTS/$SERVICE_LABEL.plist"
    rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v launchctl >/dev/null 2>&1; then
    printf '%s\n' 'launchd smoke test skipped: launchctl is unavailable.'
    exit 0
fi

export PERSONAL_OS_SERVICE_LABEL="$SERVICE_LABEL"
export PERSONAL_OS_LAUNCH_AGENTS_DIR="$AGENTS"
export PERSONAL_OS_SERVICE_SUPPORT_DIR="$SUPPORT"
export PERSONAL_OS_LOG_DIR="$LOGS"
export MAC_DETECTIVE_DATABASE="$DATABASE"
export MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS"
export MAC_DETECTIVE_FS_USAGE=0

printf '%s\n' 'Installing isolated launchd smoke service...'
"$ROOT_DIR/scripts/install-personal-os-service.sh" >/dev/null

cycles_reached=0
for _ in $(seq 1 120); do
    if [[ -s "$RUNTIME_STATUS" ]]; then
        cycles="$(plutil -extract cycles_executed raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf '0')"
        if [[ "$cycles" =~ ^[0-9]+$ ]] && (( cycles >= 2 )); then
            cycles_reached=1
            break
        fi
    fi
    sleep 0.25
done
[[ "$cycles_reached" -eq 1 ]]
[[ -f "$DATABASE" && -f "$RUNTIME_STATUS" ]]

printf '%s\n' 'Service status:'
"$ROOT_DIR/scripts/status-personal-os-service.sh" | grep -E 'service_state=|loaded=|pid=|database_present=|runtime_status_present='

pid_before="$(launchctl print "$TARGET" | sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1)"
[[ -n "$pid_before" ]]
launchctl kickstart -k "$TARGET"
sleep 2
pid_after="$(launchctl print "$TARGET" | sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1)"
[[ -n "$pid_after" && "$pid_after" != "$pid_before" ]]
printf 'restart: %s -> %s\n' "$pid_before" "$pid_after"

crash_pid="$(launchctl print "$TARGET" | sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1)"
launchctl kill SIGKILL "$TARGET"
crash_restart_pid=""
for _ in $(seq 1 100); do
    crash_restart_pid="$(launchctl print "$TARGET" 2>/dev/null | sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1)"
    if [[ -n "$crash_restart_pid" && "$crash_restart_pid" != "$crash_pid" ]]; then
        break
    fi
    sleep 0.2
done
printf 'keepalive crash restart: %s -> %s\n' "$crash_pid" "$crash_restart_pid"
[[ -n "$crash_restart_pid" && "$crash_restart_pid" != "$crash_pid" ]]

launchctl bootout "$TARGET"
"$ROOT_DIR/scripts/uninstall-personal-os-service.sh" >/dev/null
[[ -f "$DATABASE" && -f "$RUNTIME_STATUS" ]]
printf '%s\n' 'launchd smoke test passed; SQLite and runtime status were preserved.'
