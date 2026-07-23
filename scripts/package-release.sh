#!/bin/zsh
# Builds BarKeep.app and packages it as dist/BarKeep-<version>.zip for a
# GitHub release. Signs with $BARKEEP_SIGN_IDENTITY if set, else ad-hoc
# (CI has no identity; downloaders must dequarantine — see README).
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

codesign --force -s "${BARKEEP_SIGN_IDENTITY:--}" "$APP"

ZIP="dist/BarKeep-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
