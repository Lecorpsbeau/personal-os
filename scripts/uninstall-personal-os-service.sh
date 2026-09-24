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

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

read_plist_value() {
    local key="$1"
    [[ -f "$PLIST" ]] || return 0
    plutil -extract "$key" raw -o - "$PLIST" 2>/dev/null || true
}

if [[ -z "${HOME:-}" ]]; then
    printf 'HOME is required to manage a user LaunchAgent.\n' >&2
    exit 1
fi
if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
    printf 'launchctl not found: %s\n' "$LAUNCHCTL_BIN" >&2
    exit 127
fi

LAUNCH_AGENTS_DIR="$(absolute_path "$LAUNCH_AGENTS_DIR")"
PLIST="$(absolute_path "$PLIST")"
SUPPORT_DIR="$(absolute_path "$SUPPORT_DIR")"
LOG_DIR="$(absolute_path "$LOG_DIR")"
DATABASE="$(absolute_path "$DATABASE")"
RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"

if [[ -f "$PLIST" ]]; then
    DATABASE="$(read_plist_value EnvironmentVariables.MAC_DETECTIVE_DATABASE)"
    RUNTIME_STATUS="$(read_plist_value EnvironmentVariables.MAC_DETECTIVE_RUNTIME_STATUS)"
    SERVICE_BINARY="$(read_plist_value ProgramArguments.0)"
    [[ -n "$DATABASE" ]] || DATABASE="$SUPPORT_DIR/mac_detective.sqlite"
    [[ -n "$RUNTIME_STATUS" ]] || RUNTIME_STATUS="$SUPPORT_DIR/.mac-detective-runtime-status.json"
    DATABASE="$(absolute_path "$DATABASE")"
    RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"
fi

printf '%s\n' 'Stopping the Personal OS mac-detective LaunchAgent...'
"$LAUNCHCTL_BIN" bootout "$TARGET" >/dev/null 2>&1 || true
"$LAUNCHCTL_BIN" disable "$TARGET" >/dev/null 2>&1 || true

if [[ -e "$PLIST" ]]; then
    rm -f "$PLIST"
    printf 'Removed plist: %s\n' "$PLIST"
else
    printf '%s\n' 'No installed plist found; nothing to remove.'
fi

if "$LAUNCHCTL_BIN" print "$TARGET" >/dev/null 2>&1; then
    printf 'Warning: launchd still reports the service as loaded: %s\n' "$TARGET" >&2
else
    printf '%s\n' 'LaunchAgent is not loaded.'
fi

printf '%s\n' 'SQLite and logs were preserved.'
printf 'database=%s\n' "$DATABASE"
printf 'runtime_status=%s\n' "$RUNTIME_STATUS"
printf 'binary=%s\n' "$SERVICE_BINARY"
printf 'logs=%s\n' "$LOG_DIR"
printf 'service_label=%s\n' "$SERVICE_LABEL"
