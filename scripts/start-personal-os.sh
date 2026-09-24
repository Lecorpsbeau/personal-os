#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_LABEL="${PERSONAL_OS_SERVICE_LABEL:-com.personal-os.mac-detective}"
LAUNCHCTL_BIN="${PERSONAL_OS_LAUNCHCTL_BIN:-launchctl}"
SERVICE_PLIST="${PERSONAL_OS_SERVICE_PLIST:-${HOME:-$ROOT_DIR}/Library/LaunchAgents/$SERVICE_LABEL.plist}"
EXPLICIT_RUNTIME_DIR="${PERSONAL_OS_RUNTIME_DIR:-}"
EXPLICIT_DATABASE="${MAC_DETECTIVE_DATABASE:-}"
EXPLICIT_RUNTIME_STATUS="${MAC_DETECTIVE_RUNTIME_STATUS:-}"
EXPLICIT_FS_USAGE="${MAC_DETECTIVE_FS_USAGE:-}"
RUNTIME_DIR="${EXPLICIT_RUNTIME_DIR:-$ROOT_DIR/.runtime/personal-os}"
MAC_DATABASE="${EXPLICIT_DATABASE:-$RUNTIME_DIR/mac_detective.sqlite}"
RUNTIME_STATUS="${EXPLICIT_RUNTIME_STATUS:-$RUNTIME_DIR/.mac-detective-runtime-status.json}"
START_TIMEOUT="${PERSONAL_OS_START_TIMEOUT:-30}"
SHUTDOWN_TIMEOUT="${PERSONAL_OS_SHUTDOWN_TIMEOUT:-10}"
SERVICE_CONFIGURED=false
SERVICE_LOADED=false
SERVICE_FS_USAGE="$EXPLICIT_FS_USAGE"

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

read_service_value() {
    local key="$1"
    if [[ -f "$SERVICE_PLIST" ]] && command -v plutil >/dev/null 2>&1; then
        plutil -extract "$key" raw -o - "$SERVICE_PLIST" 2>/dev/null || true
    fi
}

SERVICE_PLIST="$(absolute_path "$SERVICE_PLIST")"
if [[ -f "$SERVICE_PLIST" ]]; then
    service_database="$(read_service_value EnvironmentVariables.MAC_DETECTIVE_DATABASE)"
    service_status="$(read_service_value EnvironmentVariables.MAC_DETECTIVE_RUNTIME_STATUS)"
    service_stdout="$(read_service_value StandardOutPath)"
    service_fs_usage="$(read_service_value EnvironmentVariables.MAC_DETECTIVE_FS_USAGE)"
    if [[ -z "$EXPLICIT_DATABASE" && -n "$service_database" ]]; then
        MAC_DATABASE="$service_database"
        SERVICE_CONFIGURED=true
    fi
    if [[ -z "$EXPLICIT_RUNTIME_STATUS" && -n "$service_status" ]]; then
        RUNTIME_STATUS="$service_status"
        SERVICE_CONFIGURED=true
    fi
    if [[ -z "$EXPLICIT_RUNTIME_DIR" && -n "$service_stdout" ]]; then
        RUNTIME_DIR="$(dirname -- "$service_stdout")"
        SERVICE_CONFIGURED=true
    fi
    if [[ -z "$EXPLICIT_FS_USAGE" && -n "$service_fs_usage" ]]; then
        SERVICE_FS_USAGE="$service_fs_usage"
        SERVICE_CONFIGURED=true
    fi
fi

RUNTIME_DIR="$(absolute_path "$RUNTIME_DIR")"
MAC_DATABASE="$(absolute_path "$MAC_DATABASE")"
RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"

if [[ "$SERVICE_CONFIGURED" == true ]] && command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
    if "$LAUNCHCTL_BIN" print "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1; then
        SERVICE_LOADED=true
    fi
fi

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

if ! is_positive_integer "$START_TIMEOUT"; then
    printf 'PERSONAL_OS_START_TIMEOUT must be a positive integer.\n' >&2
    exit 2
fi
if ! is_positive_integer "$SHUTDOWN_TIMEOUT"; then
    printf 'PERSONAL_OS_SHUTDOWN_TIMEOUT must be a positive integer.\n' >&2
    exit 2
fi
if [[ "$MAC_DATABASE" == "$RUNTIME_STATUS" ]]; then
    printf 'MAC_DETECTIVE_DATABASE and MAC_DETECTIVE_RUNTIME_STATUS must be different files.\n' >&2
    exit 2
fi

mkdir -p "$RUNTIME_DIR" "$(dirname -- "$MAC_DATABASE")" "$(dirname -- "$RUNTIME_STATUS")"

LOCK_DIR="$RUNTIME_DIR/launcher.lock"
LOCK_ACQUIRED=0
MAC_PID=""
DASHBOARD_PID=""
SHUTTING_DOWN=0
DESCENDANTS=()

is_launcher_process() {
    local pid="$1"
    local command
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$command" == *start-personal-os.sh* ]]
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_ACQUIRED=1
        return 0
    fi

    if [[ -f "$LOCK_DIR/pid" ]]; then
        local existing_pid
        existing_pid="$(<"$LOCK_DIR/pid")"
        if [[ "$existing_pid" =~ ^[1-9][0-9]*$ ]] \
            && kill -0 "$existing_pid" 2>/dev/null \
            && is_launcher_process "$existing_pid"; then
            printf 'Personal OS is already running (launcher PID %s).\n' "$existing_pid" >&2
            return 1
        fi
        rm -f "$LOCK_DIR/pid"
    fi

    # Only remove an empty stale lock. Unknown files are left untouched.
    if ! rmdir "$LOCK_DIR" 2>/dev/null; then
        printf 'Cannot recover stale launcher lock: %s\n' "$LOCK_DIR" >&2
        return 1
    fi
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        printf 'Cannot acquire launcher lock: %s\n' "$LOCK_DIR" >&2
        return 1
    fi
    LOCK_ACQUIRED=1
}

is_running() {
    local pid="$1"
    local state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

status_is_ready() {
    [[ -s "$RUNTIME_STATUS" && -s "$MAC_DATABASE" ]] || return 1
    command -v plutil >/dev/null 2>&1 || return 1

    local version state cycles persisted
    version="$(plutil -extract version raw -o - "$RUNTIME_STATUS" 2>/dev/null)" || return 1
    state="$(plutil -extract state raw -o - "$RUNTIME_STATUS" 2>/dev/null)" || return 1
    cycles="$(plutil -extract cycles_executed raw -o - "$RUNTIME_STATUS" 2>/dev/null)" || return 1
    persisted="$(plutil -extract last_successful_persistence_at raw -o - "$RUNTIME_STATUS" 2>/dev/null)" || return 1
    [[ "$version" == "1" && "$state" == "running" ]] || return 1
    [[ "$cycles" =~ ^[0-9]+$ && "$cycles" -ge 1 ]] || return 1
    [[ -n "$persisted" && "$persisted" != "null" ]] || return 1

    local status_mtime now_epoch
    status_mtime="$(stat -f '%m' "$RUNTIME_STATUS" 2>/dev/null || printf '0')"
    now_epoch="$(date +%s)"
    [[ "$status_mtime" =~ ^[0-9]+$ ]] || return 1
    (( now_epoch >= status_mtime && now_epoch - status_mtime <= 10 ))
}

collect_descendants() {
    local parent="$1"
    local child
    while IFS= read -r child; do
        [[ "$child" =~ ^[1-9][0-9]*$ ]] || continue
        DESCENDANTS+=("$child")
        collect_descendants "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
}

terminate_pid() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0

    DESCENDANTS=()
    if is_running "$pid"; then
        collect_descendants "$pid"
    else
        wait "$pid" 2>/dev/null || true
        return 0
    fi

    # mac-detective owns fs_usage as a child process. Stop descendants first so
    # a forced parent shutdown cannot leave the collector behind.
    if (( ${#DESCENDANTS[@]} > 0 )); then
        for child in "${DESCENDANTS[@]}"; do
            kill -TERM "$child" 2>/dev/null || true
        done
    fi
    kill -TERM "$pid" 2>/dev/null || true

    local deadline=$((SECONDS + SHUTDOWN_TIMEOUT))
    while is_running "$pid" && (( SECONDS < deadline )); do
        sleep 0.1
    done
    if is_running "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    if (( ${#DESCENDANTS[@]} > 0 )); then
        for child in "${DESCENDANTS[@]}"; do
            if is_running "$child"; then
                kill -KILL "$child" 2>/dev/null || true
            fi
        done
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    if (( SHUTTING_DOWN == 1 )); then
        return 0
    fi
    SHUTTING_DOWN=1
    terminate_pid "$DASHBOARD_PID"
    terminate_pid "$MAC_PID"
    if (( LOCK_ACQUIRED == 1 )); then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}

on_signal() {
    local signal="${1:-TERM}"
    local exit_code=130
    case "$signal" in
        HUP) exit_code=129 ;;
        TERM) exit_code=143 ;;
    esac
    printf '\nPersonal OS shutdown requested (%s).\n' "$signal" >&2
    cleanup
    exit "$exit_code"
}

if ! acquire_lock; then
    exit 1
fi
trap cleanup EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
printf '%s\n' "$$" > "$LOCK_DIR/pid"

find_binary() {
    local package_path="$1"
    local binary_name="$2"
    local override="${3:-}"

    if [[ -n "$override" ]]; then
        if [[ "$override" != /* ]]; then
            override="$ROOT_DIR/$override"
        fi
        printf '%s\n' "$override"
        return 0
    fi

    local bin_dir
    bin_dir="$(swift build --package-path "$package_path" --show-bin-path 2>/dev/null)"
    printf '%s/%s\n' "${bin_dir%/}" "$binary_name"
}

service_mac_bin="$(read_service_value ProgramArguments.0)"
if [[ -n "$service_mac_bin" ]]; then
    service_mac_bin="$(absolute_path "$service_mac_bin")"
fi
if [[ "$SERVICE_LOADED" == true && -n "$service_mac_bin" && -x "$service_mac_bin" ]]; then
    MAC_BIN="$service_mac_bin"
else
    MAC_BIN="$(find_binary "$ROOT_DIR/apps/mac-detective" mac-detective "${MAC_DETECTIVE_BIN:-}")"
fi
DASHBOARD_BIN="$(find_binary "$ROOT_DIR/apps/dashboard" PersonalOSDashboard "${DASHBOARD_BIN:-}")"

if [[ ! -x "$MAC_BIN" || ! -x "$DASHBOARD_BIN" ]]; then
    printf '%s\n' "Personal OS components are missing; building them now..."
    "$ROOT_DIR/scripts/build-personal-os.sh"
    if [[ "$SERVICE_LOADED" == true && -n "$service_mac_bin" && -x "$service_mac_bin" ]]; then
        MAC_BIN="$service_mac_bin"
    else
        MAC_BIN="$(find_binary "$ROOT_DIR/apps/mac-detective" mac-detective "${MAC_DETECTIVE_BIN:-}")"
    fi
    DASHBOARD_BIN="$(find_binary "$ROOT_DIR/apps/dashboard" PersonalOSDashboard "${DASHBOARD_BIN:-}")"
fi

if [[ ! -x "$MAC_BIN" || ! -x "$DASHBOARD_BIN" ]]; then
    printf 'Personal OS components are missing after build: %s, %s\n' "$MAC_BIN" "$DASHBOARD_BIN" >&2
    exit 1
fi

printf '%s\n' "Runtime directory: $RUNTIME_DIR"
printf '%s\n' "SQLite database: $MAC_DATABASE"
printf '%s\n' "Runtime status: $RUNTIME_STATUS"

if [[ "$SERVICE_LOADED" == true ]]; then
    printf 'mac-detective is managed by launchd (%s); starting Dashboard only.\n' "$SERVICE_LABEL"
else
    printf '%s\n' 'Starting mac-detective (no sudo)...'
    # A fresh status file prevents an old status from satisfying readiness.
    rm -f "$RUNTIME_STATUS"
    PERSONAL_OS_ROOT="$ROOT_DIR" \
    MAC_DETECTIVE_FS_USAGE="${SERVICE_FS_USAGE:-${MAC_DETECTIVE_FS_USAGE:-0}}" \
    MAC_DETECTIVE_DATABASE="$MAC_DATABASE" \
    MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS" \
        "$MAC_BIN" > "$RUNTIME_DIR/mac-detective.log" 2>&1 &
    MAC_PID=$!
fi

ready=0
iterations=$((START_TIMEOUT * 4))
for ((attempt = 0; attempt < iterations; attempt++)); do
    if [[ "$SERVICE_LOADED" == false ]] && ! is_running "$MAC_PID"; then
        if wait "$MAC_PID"; then
            mac_exit=0
        else
            mac_exit=$?
        fi
        printf 'mac-detective exited before readiness (code %s).\n' "$mac_exit" >&2
        tail -n 40 "$RUNTIME_DIR/mac-detective.log" >&2 || true
        exit 1
    fi
    if status_is_ready; then
        ready=1
        break
    fi
    sleep 0.25
done

if (( ready != 1 )); then
    printf 'Timed out waiting for SQLite and runtime status.\n' >&2
    if [[ "$SERVICE_LOADED" == false ]]; then
        tail -n 40 "$RUNTIME_DIR/mac-detective.log" >&2 || true
    fi
    exit 1
fi

printf '%s\n' 'Starting Personal OS Dashboard...'
PERSONAL_OS_ROOT="$ROOT_DIR" \
MAC_DETECTIVE_DATABASE="$MAC_DATABASE" \
MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS" \
    "$DASHBOARD_BIN" > "$RUNTIME_DIR/dashboard.log" 2>&1 &
DASHBOARD_PID=$!

while is_running "$DASHBOARD_PID"; do
    if [[ "$SERVICE_LOADED" == false ]] && ! is_running "$MAC_PID"; then
        break
    fi
    sleep 1
done

if [[ "$SERVICE_LOADED" == false ]] && ! is_running "$MAC_PID"; then
    if wait "$MAC_PID"; then
        mac_exit=0
    else
        mac_exit=$?
    fi
    printf 'mac-detective stopped unexpectedly (code %s).\n' "$mac_exit" >&2
    exit 1
fi

if ! is_running "$DASHBOARD_PID"; then
    if wait "$DASHBOARD_PID"; then
        dashboard_exit=0
    else
        dashboard_exit=$?
    fi
    printf 'Dashboard stopped unexpectedly (code %s).\n' "$dashboard_exit" >&2
    exit 1
fi

exit 0
