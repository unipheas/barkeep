#!/bin/zsh
# Builds BarKeep.app into dist/ and (re)launches it.
#
# Code signing: uses $BARKEEP_SIGN_IDENTITY if set, otherwise prefers the first
# Developer ID Application identity, then Apple Development, then ad-hoc.
# Developer ID builds use hardened runtime and a secure timestamp.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/BarKeep.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp packaging/Info.plist "$APP/Contents/Info.plist"

cp .build/release/BarKeep "$APP/Contents/MacOS/BarKeep"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${BARKEEP_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$BARKEEP_SIGN_IDENTITY"
else
    # Keychain output is not ordered by certificate type. Select Developer ID
    # explicitly so local rebuilds keep the same TCC identity as distributed builds.
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' | grep -v REVOKED \
        | head -1 | sed 's/^[^"]*"//; s/"$//' || true)"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep 'Apple Development' | grep -v REVOKED \
            | head -1 | sed 's/^[^"]*"//; s/"$//' || true)"
    fi
fi
if [ -n "$IDENTITY" ]; then
    if [[ "$IDENTITY" == Developer\ ID\ Application:* ]]; then
        codesign --force --options runtime --timestamp -s "$IDENTITY" "$APP"
    else
        codesign --force -s "$IDENTITY" "$APP"
    fi
    echo "Signed with: $IDENTITY"
else
    codesign --force -s - "$APP"
    echo "Signed ad-hoc (Full Disk Access will need re-granting after each rebuild)"
fi

pkill -x BarKeep 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Launched $APP"
