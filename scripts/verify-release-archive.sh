#!/bin/zsh
# Verifies the app exactly as users receive it after extracting a release ZIP.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <BarKeep-release.zip>" >&2
    exit 64
fi

ZIP="$1"
if [ ! -f "$ZIP" ]; then
    echo "Release archive not found: $ZIP" >&2
    exit 66
fi

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/barkeep-release-verify.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT

ditto -x -k --norsrc "$ZIP" "$VERIFY_DIR"

APP="$VERIFY_DIR/BarKeep.app"
if [ ! -d "$APP" ]; then
    echo "Release archive does not contain BarKeep.app at its root" >&2
    exit 65
fi

codesign --verify --deep --strict --verbose=2 "$APP"
echo "Verified extracted release app: $APP"
