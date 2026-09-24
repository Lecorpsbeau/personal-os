#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v swift >/dev/null 2>&1; then
    printf 'Swift toolchain not found in PATH.\n' >&2
    exit 127
fi

for package in "$ROOT_DIR/apps/mac-detective" "$ROOT_DIR/apps/dashboard"; do
    if [[ ! -d "$package" ]]; then
        printf 'Required package directory is missing: %s\n' "$package" >&2
        exit 1
    fi
done

printf '%s\n' '[1/2] Building mac-detective'
swift build --package-path "$ROOT_DIR/apps/mac-detective"

printf '%s\n' '[2/2] Building Personal OS Dashboard'
swift build --package-path "$ROOT_DIR/apps/dashboard"

printf '%s\n' 'Build complete.'
