# Contributing to BarKeep

Thanks for helping improve BarKeep. Bug reports, feature ideas, documentation
fixes, code contributions, and experimental forks are all welcome.

## Ways to contribute

- Open an issue for a reproducible bug or focused feature request.
- Improve documentation, setup instructions, or troubleshooting guidance.
- Add tests for device behavior and firmware edge cases.
- Submit a pull request for fixes or new features.
- Fork the project and adapt it for your own hardware or workflow.

For a potential security vulnerability, do not open a public issue. Follow
[SECURITY.md](SECURITY.md) instead.

## Development setup

You need:

- macOS 14 or newer
- Xcode command-line tools with Swift 5.9 or newer
- A Busy Bar for physical-device testing; the automated test suite does not
  require one

Fork the repository on GitHub, then clone your fork:

```bash
git clone git@github.com:YOUR-USER/barkeep.git
cd barkeep
git remote add upstream https://github.com/unipheas/barkeep.git
git switch -c feature/your-change
```

Build and test:

```bash
swift test
swift build
```

To assemble and launch the menu-bar app:

```bash
./make-app.sh
```

The script uses an available Developer ID or Apple Development identity when
possible and otherwise falls back to ad-hoc signing. Locally signed builds may
need macOS privacy permissions granted again.

## Pull requests

Before opening a pull request:

1. Rebase or merge the latest `upstream/main`.
2. Run `swift test` and `swift build -c release`.
3. Add or update tests for behavior changes.
4. Update the README or other public documentation when setup, behavior, or
   user-facing features change.
5. Include screenshots for visible UI changes and note the Busy Bar firmware
   version used for hardware testing.
6. Keep each pull request focused enough to review and revert independently.

GitHub Actions runs the test suite and release build for every pull request.
Maintainers may ask for changes before merging.

## Protect credentials and private data

Never commit:

- Busy Bar local HTTP API passwords or cloud API tokens
- Slack, GitHub, OpenAI, or other service tokens
- Apple app-specific passwords
- Signing certificates, private keys, provisioning profiles, or Keychain
  exports
- Notification databases, logs, screenshots, or fixtures containing private
  messages or calendar data

Use placeholders in examples and environment variables for local CLI/MCP
configuration. If a credential is committed accidentally, revoke it
immediately and tell a maintainer through a private security report.

## License

By submitting a contribution, you agree that it may be distributed under
BarKeep's [MIT License](LICENSE). You retain copyright to your contribution.
