#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME:-}"
SERVICE_LABEL="${PERSONAL_OS_SERVICE_LABEL:-com.personal-os.mac-detective}"
LAUNCHCTL_BIN="${PERSONAL_OS_LAUNCHCTL_BIN:-launchctl}"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$SERVICE_LABEL"
LAUNCH_AGENTS_DIR="${PERSONAL_OS_LAUNCH_AGENTS_DIR:-$HOME_DIR/Library/LaunchAgents}"
PLIST="${PERSONAL_OS_SERVICE_PLIST:-$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist}"
SUPPORT_DIR="${PERSONAL_OS_SERVICE_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/PersonalOS}"
LOG_DIR="${PERSONAL_OS_LOG_DIR:-$HOME_DIR/Library/Logs/PersonalOS}"
DATABASE="${MAC_DETECTIVE_DATABASE:-$SUPPORT_DIR/mac_detective.sqlite}"
RUNTIME_STATUS="${MAC_DETECTIVE_RUNTIME_STATUS:-$SUPPORT_DIR/.mac-detective-runtime-status.json}"
SERVICE_BINARY="unknown"
TEMP_OUTPUT=""

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

cleanup() {
    if [[ -n "$TEMP_OUTPUT" ]]; then
        rm -f "$TEMP_OUTPUT"
    fi
}
trap cleanup EXIT

if [[ -z "${HOME:-}" ]]; then
    printf 'HOME is required to inspect a user LaunchAgent.\n' >&2
    exit 1
fi

LAUNCH_AGENTS_DIR="$(absolute_path "$LAUNCH_AGENTS_DIR")"
PLIST="$(absolute_path "$PLIST")"
SUPPORT_DIR="$(absolute_path "$SUPPORT_DIR")"
LOG_DIR="$(absolute_path "$LOG_DIR")"
DATABASE="$(absolute_path "$DATABASE")"
RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"

read_plist_value() {
    local key="$1"
    if [[ -f "$PLIST" ]] && command -v plutil >/dev/null 2>&1; then
        plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || true
    fi
}

file_size() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf '%s' '-'
        return 0
    fi
    if stat -f '%z' "$path" >/dev/null 2>&1; then
        stat -f '%z' "$path"
    else
        wc -c < "$path" | tr -d '[:space:]'
    fi
}

pid_is_alive() {
    local pid="$1"
    local state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

if [[ -f "$PLIST" ]]; then
    plist_database="$(read_plist_value EnvironmentVariables.MAC_DETECTIVE_DATABASE)"
    plist_status="$(read_plist_value EnvironmentVariables.MAC_DETECTIVE_RUNTIME_STATUS)"
    plist_stdout="$(read_plist_value StandardOutPath)"
    plist_stderr="$(read_plist_value StandardErrorPath)"
    plist_binary="$(read_plist_value ProgramArguments.0)"
    [[ -n "$plist_binary" ]] && SERVICE_BINARY="$(absolute_path "$plist_binary")"
    [[ -n "$plist_database" ]] && DATABASE="$(absolute_path "$plist_database")"
    [[ -n "$plist_status" ]] && RUNTIME_STATUS="$(absolute_path "$plist_status")"
    [[ -n "$plist_stdout" ]] && LOG_DIR="$(dirname -- "$(absolute_path "$plist_stdout")")"
    [[ -n "$plist_stderr" ]] && LOG_DIR="$(dirname -- "$(absolute_path "$plist_stderr")")"
fi

INSTALLED=false
LOADED=false
PID=""
LAUNCHD_STATE="unknown"
LAST_EXIT_CODE="unknown"
LAUNCHCTL_AVAILABLE=false

if command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
    LAUNCHCTL_AVAILABLE=true
    TEMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/personal-os-launchctl.XXXXXX")"
    if "$LAUNCHCTL_BIN" print "$TARGET" >"$TEMP_OUTPUT" 2>&1; then
        LOADED=true
        PID="$(sed -nE 's/^[[:space:]]*pid[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$TEMP_OUTPUT" | head -n 1)"
        LAUNCHD_STATE="$(sed -nE 's/^[[:space:]]*state[[:space:]]*=[[:space:]]*([^;]+).*/\1/p' "$TEMP_OUTPUT" | head -n 1)"
        LAUNCHD_STATE="${LAUNCHD_STATE:-unknown}"
        last_exit_line="$(grep 'last exit code' "$TEMP_OUTPUT" | head -n 1 || true)"
        if [[ "$last_exit_line" == *"(never exited)"* ]]; then
            LAST_EXIT_CODE="never-exited"
        else
            LAST_EXIT_CODE="$(printf '%s\n' "$last_exit_line" | sed -nE 's/.*last exit code[[:space:]]*=[[:space:]]*([0-9-]+).*/\1/p' | head -n 1)"
            LAST_EXIT_CODE="${LAST_EXIT_CODE:-unknown}"
        fi
    fi
fi

if [[ -f "$PLIST" ]]; then
    INSTALLED=true
fi

RUNTIME_STATE="unknown"
RUNTIME_UPDATED_AT="unknown"
RUNTIME_LAST_PERSISTENCE="unknown"
RUNTIME_CYCLES="unknown"
RUNTIME_FS_USAGE_STATE="unknown"
RUNTIME_FS_USAGE_DIAGNOSTIC="unknown"
RUNTIME_AGE="unknown"
RUNTIME_PRESENT=false
if [[ -f "$RUNTIME_STATUS" ]] && command -v plutil >/dev/null 2>&1; then
    RUNTIME_PRESENT=true
    RUNTIME_STATE="$(plutil -extract state raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    RUNTIME_UPDATED_AT="$(plutil -extract updated_at raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    RUNTIME_LAST_PERSISTENCE="$(plutil -extract last_successful_persistence_at raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    RUNTIME_CYCLES="$(plutil -extract cycles_executed raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    RUNTIME_FS_USAGE_STATE="$(plutil -extract fs_usage.state raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    RUNTIME_FS_USAGE_DIAGNOSTIC="$(plutil -extract fs_usage.diagnostic raw -o - "$RUNTIME_STATUS" 2>/dev/null || printf 'unknown')"
    status_mtime="$(stat -f '%m' "$RUNTIME_STATUS" 2>/dev/null || printf '0')"
    now_epoch="$(date +%s)"
    if [[ "$status_mtime" =~ ^[0-9]+$ ]] && (( now_epoch >= status_mtime )); then
        RUNTIME_AGE="$((now_epoch - status_mtime))s"
    fi
fi

DATABASE_PRESENT=false
[[ -f "$DATABASE" ]] && DATABASE_PRESENT=true
RUNTIME_FRESH=false
RUNTIME_STALE=false
if [[ "$RUNTIME_AGE" != "unknown" && "${RUNTIME_AGE%s}" -le 10 ]]; then
    if [[ "$RUNTIME_CYCLES" =~ ^[0-9]+$ ]] && (( RUNTIME_CYCLES >= 1 )) && \
        [[ "$RUNTIME_LAST_PERSISTENCE" != "unknown" && "$RUNTIME_LAST_PERSISTENCE" != "null" && -n "$RUNTIME_LAST_PERSISTENCE" ]]; then
        RUNTIME_FRESH=true
    fi
elif [[ "$RUNTIME_AGE" != "unknown" && "${RUNTIME_AGE%s}" -gt 10 ]]; then
    RUNTIME_STALE=true
fi
LAST_EXIT_FAILED=false
if [[ "$LAST_EXIT_CODE" =~ ^-?[0-9]+$ ]] && [[ "$LAST_EXIT_CODE" != "0" ]]; then
    LAST_EXIT_FAILED=true
fi
PID_ALIVE=false
if [[ -n "$PID" ]] && pid_is_alive "$PID"; then
    PID_ALIVE=true
fi

OVERALL="UNKNOWN"
if [[ "$INSTALLED" == false ]]; then
    OVERALL="NOT_INSTALLED"
elif [[ "$LOADED" == false ]]; then
    OVERALL="NOT_LOADED"
elif [[ "$PID_ALIVE" == true ]]; then
    if [[ "$RUNTIME_STATE" == "failed" || "$LAST_EXIT_FAILED" == true ]]; then
        OVERALL="FAILED"
    elif [[ "$RUNTIME_STATE" == "running" && "$RUNTIME_FRESH" == true && "$DATABASE_PRESENT" == true ]]; then
        OVERALL="RUNNING"
    elif [[ "$RUNTIME_STALE" == true ]]; then
        OVERALL="STALE"
    else
        OVERALL="STARTING"
    fi
else
    if [[ "$RUNTIME_STATE" == "failed" || "$LAST_EXIT_FAILED" == true ]]; then
        OVERALL="FAILED"
    elif [[ "$RUNTIME_STATE" == "stopped" ]]; then
        OVERALL="LOADED_NOT_RUNNING"
    elif [[ "$RUNTIME_STALE" == true ]]; then
        OVERALL="STALE"
    else
        OVERALL="LOADED_NOT_RUNNING"
    fi
fi

printf 'service_state=%s\n' "$OVERALL"
printf 'label=%s\n' "$SERVICE_LABEL"
printf 'domain=%s\n' "$DOMAIN"
printf 'installed=%s\n' "$INSTALLED"
printf 'loaded=%s\n' "$LOADED"
printf 'launchctl_available=%s\n' "$LAUNCHCTL_AVAILABLE"
printf 'launchd_state=%s\n' "$LAUNCHD_STATE"
printf 'pid=%s\n' "${PID:-unknown}"
printf 'pid_alive=%s\n' "$PID_ALIVE"
printf 'last_exit_code=%s\n' "$LAST_EXIT_CODE"
printf 'runtime_state=%s\n' "$RUNTIME_STATE"
printf 'runtime_updated_at=%s\n' "$RUNTIME_UPDATED_AT"
printf 'runtime_cycles=%s\n' "$RUNTIME_CYCLES"
printf 'runtime_last_persistence=%s\n' "$RUNTIME_LAST_PERSISTENCE"
printf 'runtime_status_age=%s\n' "$RUNTIME_AGE"
printf 'fs_usage_state=%s\n' "$RUNTIME_FS_USAGE_STATE"
printf 'fs_usage_diagnostic=%s\n' "$RUNTIME_FS_USAGE_DIAGNOSTIC"
printf 'database=%s\n' "$DATABASE"
printf 'database_present=%s\n' "$DATABASE_PRESENT"
printf 'database_bytes=%s\n' "$(file_size "$DATABASE")"
printf 'runtime_status=%s\n' "$RUNTIME_STATUS"
printf 'runtime_status_present=%s\n' "$RUNTIME_PRESENT"
printf 'stdout_log=%s\n' "$LOG_DIR/mac-detective.stdout.log"
printf 'stdout_log_bytes=%s\n' "$(file_size "$LOG_DIR/mac-detective.stdout.log")"
printf 'stderr_log=%s\n' "$LOG_DIR/mac-detective.stderr.log"
printf 'stderr_log_bytes=%s\n' "$(file_size "$LOG_DIR/mac-detective.stderr.log")"
printf 'log_rotation_max_bytes=%s\n' "${PERSONAL_OS_LOG_MAX_BYTES:-10485760}"
printf 'log_rotation_command=%s rotate\n' "$ROOT_DIR/scripts/rotate-personal-os-logs.sh"
printf 'binary=%s\n' "$SERVICE_BINARY"
printf 'plist=%s\n' "$PLIST"
