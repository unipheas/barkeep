#!/bin/zsh
# Builds BarKeep.app into dist/ and (re)launches it.
#
# Code signing: uses $BARKEEP_SIGN_IDENTITY if set, otherwise the first valid
# "Apple Development" identity in your keychain, otherwise an ad-hoc signature.
# A stable identity matters: macOS ties the Full Disk Access grant (needed for
# notification forwarding) to the signature, and ad-hoc signatures change on
# every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/BarKeep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp packaging/Info.plist "$APP/Contents/Info.plist"

cp .build/release/BarKeep "$APP/Contents/MacOS/BarKeep"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${BARKEEP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Apple Development' | grep -v REVOKED | head -1 | sed 's/^[^"]*"//; s/"$//')}"
if [ -n "$IDENTITY" ]; then
    codesign --force -s "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force -s - "$APP"
    echo "Signed ad-hoc (Full Disk Access will need re-granting after each rebuild)"
fi

pkill -x BarKeep 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP"
