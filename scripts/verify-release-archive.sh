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
plutil -lint "$APP/Contents/Info.plist"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist")"
if [[ "$bundle_id" != dev.barkeep.mac || "$bundle_executable" != BarKeep || ! -x "$APP/Contents/MacOS/BarKeep" ]]; then
    echo 'Release archive has an invalid app identity or missing executable' >&2
    exit 65
fi
for resource in AppIcon.icns THIRD_PARTY_NOTICES.md; do
    if [[ ! -s "$APP/Contents/Resources/$resource" ]]; then
        echo "Release archive is missing $resource" >&2
        exit 65
    fi
done
lipo -archs "$APP/Contents/MacOS/BarKeep"
echo "Verified extracted release app: $APP"
