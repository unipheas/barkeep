#!/bin/zsh
# Builds BarKeep.app and packages it as dist/BarKeep-<version>.zip for a
# GitHub release. A Developer ID identity enables hardened-runtime signing.
# Set BARKEEP_NOTARY_PROFILE to a notarytool keychain profile to notarize and
# staple the app before creating the final archive.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)}"

swift build -c release

APP="dist/BarKeep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp .build/release/BarKeep "$APP/Contents/MacOS/BarKeep"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${BARKEEP_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
else
    codesign --force -s "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="dist/BarKeep-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${BARKEEP_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" \
        --keychain-profile "$BARKEEP_NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
