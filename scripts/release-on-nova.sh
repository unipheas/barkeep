#!/bin/zsh
# Production-only wrapper. Does not create/store credentials or publish assets.
set -euo pipefail
cd "$(dirname "$0")/.."

export BARKEEP_SIGN_IDENTITY="${BARKEEP_SIGN_IDENTITY:-Developer ID Application: Brian Phillips (29J6W54RW6)}"
export BARKEEP_NOTARY_PROFILE="${BARKEEP_NOTARY_PROFILE:-BarKeep-Nova}"

if [[ "$BARKEEP_SIGN_IDENTITY" != Developer\ ID\ Application:* || "$BARKEEP_SIGN_IDENTITY" != *"(29J6W54RW6)" ]]; then
    print -u2 'A Developer ID Application identity for team 29J6W54RW6 is required.'
    exit 78
fi
identities="$(security find-identity -v -p codesigning)"
if [[ "$identities" != *\"${BARKEEP_SIGN_IDENTITY}\"* ]]; then
    print -u2 "Missing signing identity: $BARKEEP_SIGN_IDENTITY"
    print -u2 'Complete the approved local signing setup described in docs/releasing.md.'
    exit 78
fi

# Authenticated read only: validate existing credentials without retrieving them.
if ! xcrun notarytool history --keychain-profile "$BARKEEP_NOTARY_PROFILE" >/dev/null; then
    print -u2 "Existing notarization profile is unavailable: $BARKEEP_NOTARY_PROFILE"
    exit 78
fi
if [[ "${1:-}" == --check ]]; then
    print 'Production signing and notarization prerequisites are available.'
    exit 0
fi

version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "$version" ) ]]; then
    print -u2 "Usage: $0 [--check|$version]"
    exit 64
fi
./scripts/package-release.sh "$version"
print 'Signed, notarized archive prepared locally. No tag, release or Homebrew change was published.'
