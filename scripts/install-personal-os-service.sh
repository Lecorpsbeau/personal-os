#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="${HOME:-}"
SERVICE_LABEL="${PERSONAL_OS_SERVICE_LABEL:-com.personal-os.mac-detective}"
LAUNCHCTL_BIN="${PERSONAL_OS_LAUNCHCTL_BIN:-launchctl}"
SWIFT_BIN="${PERSONAL_OS_SWIFT_BIN:-swift}"
DOMAIN="gui/$(id -u)"
TARGET="$DOMAIN/$SERVICE_LABEL"
LAUNCH_AGENTS_DIR="${PERSONAL_OS_LAUNCH_AGENTS_DIR:-$HOME_DIR/Library/LaunchAgents}"
SUPPORT_DIR="${PERSONAL_OS_SERVICE_SUPPORT_DIR:-$HOME_DIR/Library/Application Support/PersonalOS}"
SERVICE_BIN_DIR="${PERSONAL_OS_SERVICE_BIN_DIR:-$SUPPORT_DIR/bin}"
LOG_DIR="${PERSONAL_OS_LOG_DIR:-$HOME_DIR/Library/Logs/PersonalOS}"
DATABASE="${MAC_DETECTIVE_DATABASE:-$SUPPORT_DIR/mac_detective.sqlite}"
RUNTIME_STATUS="${MAC_DETECTIVE_RUNTIME_STATUS:-$SUPPORT_DIR/.mac-detective-runtime-status.json}"
FS_USAGE="${MAC_DETECTIVE_FS_USAGE:-0}"
PLIST="${PERSONAL_OS_SERVICE_PLIST:-$LAUNCH_AGENTS_DIR/$SERVICE_LABEL.plist}"
TEMP_PLIST=""
TEMP_BINARY=""

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

cleanup() {
    if [[ -n "$TEMP_PLIST" ]]; then
        rm -f "$TEMP_PLIST"
    fi
    if [[ -n "$TEMP_BINARY" ]]; then
        rm -f "$TEMP_BINARY"
    fi
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Personal OS launchd installation requires macOS.\n' >&2
    exit 1
fi
if [[ -z "${HOME:-}" ]]; then
    printf 'HOME is required to install a user LaunchAgent.\n' >&2
    exit 1
fi
if ! command -v "$SWIFT_BIN" >/dev/null 2>&1; then
    printf 'Swift toolchain not found: %s\n' "$SWIFT_BIN" >&2
    exit 127
fi
if ! command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1; then
    printf 'launchctl not found: %s\n' "$LAUNCHCTL_BIN" >&2
    exit 127
fi
if ! command -v plutil >/dev/null 2>&1; then
    printf 'plutil is required.\n' >&2
    exit 127
fi
if [[ -z "$SERVICE_LABEL" || "$SERVICE_LABEL" == */* ]]; then
    printf 'Invalid launchd service label: %s\n' "$SERVICE_LABEL" >&2
    exit 2
fi

DATABASE="$(absolute_path "$DATABASE")"
RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"
SUPPORT_DIR="$(absolute_path "$SUPPORT_DIR")"
SERVICE_BIN_DIR="$(absolute_path "$SERVICE_BIN_DIR")"
LOG_DIR="$(absolute_path "$LOG_DIR")"
LAUNCH_AGENTS_DIR="$(absolute_path "$LAUNCH_AGENTS_DIR")"
PLIST="$(absolute_path "$PLIST")"

if [[ "$DATABASE" == "$RUNTIME_STATUS" ]]; then
    printf 'Database and runtime status paths must be different.\n' >&2
    exit 2
fi

printf '%s\n' '[1/5] Building mac-detective'
"$SWIFT_BIN" build --package-path "$ROOT_DIR/apps/mac-detective"

BIN_DIR="$("$SWIFT_BIN" build --package-path "$ROOT_DIR/apps/mac-detective" --show-bin-path)"
BUILT_MAC_BIN="$BIN_DIR/mac-detective"
SOURCE_MAC_BIN="${PERSONAL_OS_MAC_DETECTIVE_BIN:-${MAC_DETECTIVE_BIN:-$BUILT_MAC_BIN}}"
SOURCE_MAC_BIN="$(absolute_path "$SOURCE_MAC_BIN")"
if [[ ! -x "$SOURCE_MAC_BIN" ]]; then
    printf 'mac-detective binary is missing or not executable: %s\n' "$SOURCE_MAC_BIN" >&2
    exit 1
fi

printf '%s\n' '[2/5] Preparing user service directories and binary'
mkdir -p "$LAUNCH_AGENTS_DIR" "$SUPPORT_DIR" "$SERVICE_BIN_DIR" "$LOG_DIR" \
    "$(dirname -- "$DATABASE")" "$(dirname -- "$RUNTIME_STATUS")"
TEMP_BINARY="$(mktemp "$SERVICE_BIN_DIR/mac-detective.tmp.XXXXXX")"
cp "$SOURCE_MAC_BIN" "$TEMP_BINARY"
chmod 0755 "$TEMP_BINARY"
mv -f "$TEMP_BINARY" "$SERVICE_BIN_DIR/mac-detective"
TEMP_BINARY=""
touch "$LOG_DIR/mac-detective.stdout.log" "$LOG_DIR/mac-detective.stderr.log"
MAC_BIN="$SERVICE_BIN_DIR/mac-detective"

printf '%s\n' '[3/5] Generating LaunchAgent plist'
TEMP_PLIST="$(mktemp "$PLIST.tmp.XXXXXX")"
PERSONAL_OS_SERVICE_LABEL="$SERVICE_LABEL" \
PERSONAL_OS_ROOT="$ROOT_DIR" \
PERSONAL_OS_MAC_DETECTIVE_BIN="$MAC_BIN" \
PERSONAL_OS_LOG_DIR="$LOG_DIR" \
MAC_DETECTIVE_DATABASE="$DATABASE" \
MAC_DETECTIVE_RUNTIME_STATUS="$RUNTIME_STATUS" \
MAC_DETECTIVE_FS_USAGE="$FS_USAGE" \
    "$ROOT_DIR/scripts/generate-personal-os-plist.sh" "$TEMP_PLIST" >/dev/null
plutil -lint "$TEMP_PLIST" >/dev/null

printf '%s\n' '[4/5] Replacing and bootstrapping the user service'
"$LAUNCHCTL_BIN" bootout "$TARGET" >/dev/null 2>&1 || true
mv -f "$TEMP_PLIST" "$PLIST"
TEMP_PLIST=""
chmod 0644 "$PLIST"
"$LAUNCHCTL_BIN" enable "$TARGET" >/dev/null 2>&1 || true
if ! "$LAUNCHCTL_BIN" bootstrap "$DOMAIN" "$PLIST"; then
    printf 'launchctl bootstrap failed for %s\n' "$TARGET" >&2
    exit 1
fi

printf '%s\n' '[5/5] Verifying service registration'
if ! "$LAUNCHCTL_BIN" print "$TARGET" >/dev/null; then
    printf 'Service was not registered with launchd: %s\n' "$TARGET" >&2
    exit 1
fi

printf '%s\n' 'Personal OS mac-detective service installed.'
printf 'label=%s\n' "$SERVICE_LABEL"
printf 'plist=%s\n' "$PLIST"
printf 'binary=%s\n' "$MAC_BIN"
printf 'database=%s\n' "$DATABASE"
printf 'runtime_status=%s\n' "$RUNTIME_STATUS"
printf 'stdout=%s\n' "$LOG_DIR/mac-detective.stdout.log"
printf 'stderr=%s\n' "$LOG_DIR/mac-detective.stderr.log"
printf 'fs_usage=%s\n' "$FS_USAGE"
printf 'Use %s to inspect runtime state.\n' "$ROOT_DIR/scripts/status-personal-os-service.sh"
