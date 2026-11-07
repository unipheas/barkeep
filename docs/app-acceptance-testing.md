# Native app acceptance and coverage

The ordinary Swift suite uses isolated services. The coverage gate reconciles its
report against the recursive production Swift source inventory. Two generated
static JSON catalogs have no LLVM executable-line mapping; only their reviewed
content hashes may be absent. New or changed missing files fail the gate.
The executable entry point and real native panels additionally require an app host.
`scripts/test-app-acceptance.py` builds a temporary app with XcodeGen; it does not
install or replace BarKeep. XcodeGen and an interactive macOS session must already
be available. Do not grant new macOS permissions merely to make a test pass.

## Modes

- `python3 scripts/test-app-acceptance.py`: fixture-backed real app startup,
  Controls scene, and normal Quit/profile flush.
- `BARKEEP_ACCEPTANCE_XCUITEST=1 python3 scripts/test-app-acceptance.py`: real
  native UI interactions with fixture services, temporary files and preferences.
- `BARKEEP_ACCEPTANCE_NORMAL=1 python3 scripts/test-app-acceptance.py`: ordinary
  production factory with a loopback HTTP endpoint and launch-argument settings.
  This mode still performs real CoreAudio activity metadata monitoring and local
  network discovery. It does not capture audio, send requests to a real bar, or
  authorize new permissions. It must not be described as hardware-isolated.
- `BARKEEP_ACCEPTANCE_LOGIN=1 python3 scripts/test-app-acceptance.py`: separately
  opt-in Login Items acceptance. Obtain explicit approval before running it. It
  uses a unique test bundle, checks service status, and verifies removal after
  any registration attempt. A preflight failure is not successful registration
  coverage. Preserve artifacts and investigate if cleanup is uncertain.

The script prints the temporary artifact directory. Logs, test results, and LLVM
profiles remain there for review. Fixture defaults use a unique namespace, and
normal mode overrides only its own test application's preferences. External
fixture requests fail closed. Tests must not use a production device/password.

## Honest combined coverage

Freeze production sources for the complete run. Run `swift test
--enable-code-coverage`, preserve its default.profdata, then run the app modes.
Merge those profiles with `xcrun llvm-profdata merge -sparse`. Export the merged
profile against **only the ordinary BarKeepTests executable**, then run:

```
python3 scripts/check-coverage.py combined.json --minimum 100
```

Do not add the acceptance executable with llvm-cov `-object`: its conditional
factory has different coverage mappings and can hide the ordinary factory branch.
Do not combine profiles from different production source snapshots. Record source
hashes, toolchain, test counts, mode outcomes, and skipped checks alongside the
report. A rounded 100% display is not a passing exact 100% gate. Failed acceptance
runs, simulated hardware, or unknown platform outcomes must be reported as such.

A successful unit run alone does not prove app-level acceptance or satisfy a
whole-source release coverage gate. The release must remain blocked when the
requested gate or any required acceptance/cleanup verification fails.

## Reproducible gate wrapper

Run `python3 scripts/test-full-coverage.py --with-login-item-test` after approval
for the isolated Login Items test. Without that explicit flag the wrapper skips
Login Items, but still enforces the unchanged exact 100% threshold. It never
weakens the gate to accommodate a skipped test.

Each invocation creates a fresh `coverage-artifacts/run-*` directory. The wrapper
preserves the successful unit profile and ordinary XCTest executable before
acceptance builds, checks the production-source digest throughout, and merges
only successful, matching-source profiles. The executable is discovered from the
debug directory derived from `swift test --show-codecov-path`, supporting both
BarKeepPackageTests and BarKeepTests. Only that executable is exported.

The manifest, command stdout/stderr, profiles, acceptance logs and xcresult
bundles are retained, including on failure. Acceptance build products remain in
the original temporary directory printed in the logs; they are not duplicated.
Both CI workflows upload diagnostics even after a failing gate. They install
XcodeGen through Homebrew on the ephemeral runner and explicitly opt into the
isolated Login Items test. A hosted runner may lack a usable interactive session
or existing UI automation authorization. Such a failure blocks the workflow;
it is not permission to grant access, change security settings, skip a required
mode, or claim platform coverage from injected boundary-contract tests.
