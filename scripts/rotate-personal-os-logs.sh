#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${PERSONAL_OS_LOG_DIR:-${HOME:-$ROOT_DIR}/Library/Logs/PersonalOS}"
MAX_BYTES="${PERSONAL_OS_LOG_MAX_BYTES:-10485760}"
MODE="${1:-check}"

if [[ ! "$MAX_BYTES" =~ ^[1-9][0-9]*$ ]]; then
    printf 'PERSONAL_OS_LOG_MAX_BYTES must be a positive integer.\n' >&2
    exit 2
fi

case "$MODE" in
    check|rotate) ;;
    *)
        printf 'Usage: %s [check|rotate]\n' "$0" >&2
        exit 2
        ;;
esac

if [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="$ROOT_DIR/$LOG_DIR"
fi

file_size() {
    local path="$1"
    if stat -f '%z' "$path" >/dev/null 2>&1; then
        stat -f '%z' "$path"
    else
        wc -c < "$path" | tr -d '[:space:]'
    fi
}

mkdir -p "$LOG_DIR"

for name in mac-detective.stdout.log mac-detective.stderr.log; do
    path="$LOG_DIR/$name"
    if [[ ! -f "$path" ]]; then
        printf '%s: missing\n' "$path"
        continue
    fi
    size="$(file_size "$path")"
    if (( size < MAX_BYTES )); then
        printf '%s: %s bytes\n' "$path" "$size"
        continue
    fi
    if [[ "$MODE" == check ]]; then
        printf '%s: rotation needed (%s bytes)\n' "$path" "$size"
        continue
    fi

    # Keep the active inode so launchd's already-open stdout/stderr descriptor
    # continues writing to the active file after rotation.
    backup="$path.1"
    rm -f "$backup"
    cp "$path" "$backup"
    : > "$path"
    chmod 0644 "$path"
    printf '%s: rotated to %s (active file preserved)\n' "$path" "$backup"
done
