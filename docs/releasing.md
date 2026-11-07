# Releasing BarKeep from Nova

BarKeep ships a Developer ID signed, notarized ZIP through GitHub Releases.
The Homebrew cask is `unipheas/barkeep/barkeep`, maintained in
[`unipheas/homebrew-barkeep`](https://github.com/unipheas/homebrew-barkeep/blob/main/Casks/barkeep.rb).
Creating a tag only runs Swift tests; it does not sign or publish the app.

## One-time local setup (requires explicit credential-action approval)

The production team is Brian Phillips (`29J6W54RW6`). Nova is configured with a local Developer ID Application identity for this
team and notarization profile `BarKeep-Nova` in its login Keychain. The
following steps describe the approved setup used on October 19, 2026; do not
repeat credential creation on an already configured machine.

1. The owner signs into their Apple Account in **Xcode → Settings → Accounts**
   on Nova, completing Apple password/2FA prompts directly in Apple's UI.
   Confirm the paid developer team and authority to create Developer ID
   certificates. Cached team metadata is not proof of current membership.
2. After explicit approval, use **Manage Certificates → + → Developer ID
   Application** to create a local signing key and certificate for the same
   team. Keep the private key in Nova's login Keychain. Do not revoke other
   certificates, export keys, broaden keychain ACLs, or use a different team.
   If Apple requires membership renewal, legal terms, revocation, or a
   different setup, stop and obtain separate instructions.
3. After explicit approval, the owner creates one app-specific password at
   `https://account.apple.com/`, labeled **BarKeep Nova notarization**. If a
   usable existing notarization credential is available, reuse it instead of
   creating another. Store it locally using the command below, substituting
   the nonsecret Apple Account address. Enter the secret only into
   notarytool's hidden terminal prompt, never in command arguments, chat,
   source files, shell history, or environment variables.

   ```sh
   xcrun notarytool store-credentials BarKeep-Nova \
     --apple-id '<developer Apple Account address>' \
     --team-id 29J6W54RW6 \
     --keychain "$HOME/Library/Keychains/login.keychain-db"
   ```

   The command validates and stores the credential in the local login
   Keychain. It deliberately omits `--sync`. Do not add GitHub secrets, CI
   credentials, API keys, persistent shell exports, or new keychain access
   permissions as part of this local setup. Apple app-specific passwords
   are not a notarization-only permission scope; this workflow uses the
   dedicated credential only for notarization.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[Xcode certificate management](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates),
[app-specific passwords](https://support.apple.com/en-us/102654),
[notarytool workflow](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).
The installed `xcrun notarytool store-credentials --help` documents the hidden
password prompt and explicit keychain location.

## Build and verify each release

Start from the merged, passing main commit, preserve local edits, and verify
that the intended version/tag/release does not already exist. Use the version in `packaging/Info.plist` and verify it matches the intended release.

```sh
swift test
swift build -c release
./scripts/release-on-nova.sh --check
./scripts/release-on-nova.sh
```

The production wrapper requires Developer ID and a working existing notary
profile before invoking the existing packaging script. That script signs with
hardened runtime/timestamp, submits to Apple, staples the ticket, checks
Gatekeeper acceptance, creates the final ZIP and verifies a fresh extraction.
The wrapper does not generate or store credentials, create tags, or publish.
A `*-local-validation.zip` or ad-hoc build is never a production release asset.

## Publish and make the release available through Homebrew

1. Verify the final ZIP contains the intended app version and ARM64 executable,
   valid production signature and notarization ticket. Publish that exact ZIP
   as `BarKeep-<version>.zip` in the corresponding GitHub release. Monitor the
   tag's verification workflow to success.
2. Download the uploaded asset again. Check its SHA-256, extracted app version,
   signature, staple and Gatekeeper acceptance. Compute the cask checksum
   from this verified final downloadable ZIP, not from an earlier unsigned or
   unstapled archive.
3. Update `Casks/barkeep.rb` in `unipheas/homebrew-barkeep` with the version and
   that SHA-256 through its normal PR workflow. Do not move the cask to a
   version whose downloadable ZIP is missing or unverified.
4. Verify the public cask resolves the new version, correct URL and matching
   SHA-256. The work-computer update command is:

   ```sh
   brew update
   brew upgrade --cask unipheas/barkeep/barkeep
   ```

Do not operate on the user's work computer as part of publication.
