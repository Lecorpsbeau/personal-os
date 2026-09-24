#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${PERSONAL_OS_PLIST_TEMPLATE:-$ROOT_DIR/deploy/com.personal-os.mac-detective.plist}"
OUTPUT="${1:-}"

if [[ -z "$OUTPUT" ]]; then
    printf 'Usage: %s /absolute/path/to/service.plist\n' "$0" >&2
    exit 2
fi

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

MAC_BIN="${PERSONAL_OS_MAC_DETECTIVE_BIN:-${MAC_DETECTIVE_BIN:-}}"
REPOSITORY_ROOT="${PERSONAL_OS_ROOT:-$ROOT_DIR}"
DATABASE="${MAC_DETECTIVE_DATABASE:-}"
RUNTIME_STATUS="${MAC_DETECTIVE_RUNTIME_STATUS:-}"
LOG_DIR="${PERSONAL_OS_LOG_DIR:-}"
FS_USAGE="${MAC_DETECTIVE_FS_USAGE:-0}"
SERVICE_LABEL="${PERSONAL_OS_SERVICE_LABEL:-com.personal-os.mac-detective}"
OUTPUT="$(absolute_path "$OUTPUT")"

if [[ -z "$MAC_BIN" ]]; then
    printf 'PERSONAL_OS_MAC_DETECTIVE_BIN is required.\n' >&2
    exit 2
fi
if [[ -z "$DATABASE" || -z "$RUNTIME_STATUS" || -z "$LOG_DIR" ]]; then
    printf 'MAC_DETECTIVE_DATABASE, MAC_DETECTIVE_RUNTIME_STATUS and PERSONAL_OS_LOG_DIR are required.\n' >&2
    exit 2
fi

MAC_BIN="$(absolute_path "$MAC_BIN")"
REPOSITORY_ROOT="$(absolute_path "$REPOSITORY_ROOT")"
DATABASE="$(absolute_path "$DATABASE")"
RUNTIME_STATUS="$(absolute_path "$RUNTIME_STATUS")"
LOG_DIR="$(absolute_path "$LOG_DIR")"

if [[ ! -f "$TEMPLATE" ]]; then
    printf 'LaunchAgent template not found: %s\n' "$TEMPLATE" >&2
    exit 1
fi
if [[ ! -d "$REPOSITORY_ROOT" ]]; then
    printf 'Repository root does not exist: %s\n' "$REPOSITORY_ROOT" >&2
    exit 1
fi
if [[ "$DATABASE" == "$RUNTIME_STATUS" ]]; then
    printf 'Database and runtime status paths must be different.\n' >&2
    exit 2
fi
if [[ -z "$SERVICE_LABEL" || "$SERVICE_LABEL" == */* ]]; then
    printf 'Invalid launchd service label: %s\n' "$SERVICE_LABEL" >&2
    exit 2
fi

FS_USAGE_NORMALIZED="$(printf '%s' "$FS_USAGE" | tr '[:upper:]' '[:lower:]')"
case "$FS_USAGE_NORMALIZED" in
    0|false|no|off|1|true|yes|on) ;;
    *)
        printf 'MAC_DETECTIVE_FS_USAGE must be a boolean value.\n' >&2
        exit 2
        ;;
esac

if ! command -v plutil >/dev/null 2>&1; then
    printf 'plutil is required to generate the launchd plist.\n' >&2
    exit 127
fi

mkdir -p "$(dirname -- "$OUTPUT")"
TEMP_PLIST="$(mktemp "${OUTPUT}.tmp.XXXXXX")"
cleanup() {
    rm -f "$TEMP_PLIST"
}
trap cleanup EXIT

cp "$TEMPLATE" "$TEMP_PLIST"
plutil -replace Label -string "$SERVICE_LABEL" "$TEMP_PLIST"
plutil -remove ProgramArguments.0 "$TEMP_PLIST"
plutil -insert ProgramArguments.0 -string "$MAC_BIN" "$TEMP_PLIST"
plutil -replace WorkingDirectory -string "$REPOSITORY_ROOT" "$TEMP_PLIST"
plutil -replace EnvironmentVariables.PERSONAL_OS_ROOT -string "$REPOSITORY_ROOT" "$TEMP_PLIST"
plutil -replace EnvironmentVariables.MAC_DETECTIVE_DATABASE -string "$DATABASE" "$TEMP_PLIST"
plutil -replace EnvironmentVariables.MAC_DETECTIVE_RUNTIME_STATUS -string "$RUNTIME_STATUS" "$TEMP_PLIST"
plutil -replace EnvironmentVariables.MAC_DETECTIVE_FS_USAGE -string "$FS_USAGE" "$TEMP_PLIST"
plutil -replace StandardOutPath -string "$LOG_DIR/mac-detective.stdout.log" "$TEMP_PLIST"
plutil -replace StandardErrorPath -string "$LOG_DIR/mac-detective.stderr.log" "$TEMP_PLIST"
plutil -lint "$TEMP_PLIST" >/dev/null
mv -f "$TEMP_PLIST" "$OUTPUT"
chmod 0644 "$OUTPUT"
printf '%s\n' "$OUTPUT"
