# Actual-app startup acceptance proof

Run `python3 scripts/test-app-acceptance.py` on a macOS graphical login session
with Xcode and xcodegen already installed. The script installs nothing, does not
use production signing credentials, and does not kill an existing BarKeep app.

The temporary application target compiles the actual production `@main` type,
application initializer, scene body, and controls-window implementation. Only
AppState construction uses acceptance fixtures, selected by the explicit
`BARKEEP_APP_ACCEPTANCE` compilation flag. This flag is absent from normal
Swift package and release builds. `startServices` stays true.

Fixture transport intercepts every URL and returns an error without network
access. Audio calls, calendar source, notification paths, and Bonjour browser
are supplied through existing constructor dependencies. Optional services are
disabled in a unique temporary defaults suite, which is removed before normal
termination and by the parent script in a finally block after abnormal exits.
The support validates the exact acceptance prefix and UUID suffix before any
preferences access; arbitrary domain names fail closed. These are isolated
transient persistent writes, not an in-memory defaults store. The app has a separate bundle identity. The startup proof does not
press settings controls, start games, request OS permissions, or show file panels.

The acceptance process uses its own AppKit window list to assert that the real
`--show-window` launch path produced visible controls. It also requires startup
fixture browser activity and intercepted HTTP requests. It writes a JSON result
and calls normal `NSApp.terminate`; the script requires exit success, nonempty
LLVM profiles, successful profile merge, and successful coverage export. A
25-second parent timeout kills only its directly launched acceptance child.
Artifacts are retained in the printed temporary directory for inspection.

The exported coverage is acceptance-build-only evidence. Do not replace the
normal unit-test coverage report with it. In particular, the ordinary
`AppState()` construction branch is compiled out of this target and is NOT
covered by fixture startup. For the gate, merge raw profiles but export ONLY against the normal unit-test
production binary. Both builds use module name BarKeep and DEBUG; only matching
function hashes should receive acceptance evidence. Do not use multi-object
exports: they can omit normal conditional branches or double-count files. The
small makeApplicationState factory has different conditional implementations;
fixture construction does not establish coverage of its normal AppState() call. No exclusions or 100% claims are made here.

The startup-only proof does not cover other scene windows or native panels.
The opt-in UI mode below exercises those separately. Never extend it to real
calendar data, notification databases, credentials, global input capture, or
OS permission approval.

## Optional scene probe

`BARKEEP_ACCEPTANCE_SCENES=1 python3 scripts/test-app-acceptance.py` selects real
native tabs and attempts same-process accessibility presses for Canvas and
Device Controls. It currently fails because SwiftUI button nodes are not
exposed through the inspected accessibility tree. Action/result flags are
recorded; this is not evidence of an openWindow defect because those buttons
have not been activated. No external accessibility grants are requested.

## XCUITest scenes

`BARKEEP_ACCEPTANCE_XCUITEST=1 python3 scripts/test-app-acceptance.py` builds a
separate UI runner against the fixture app and clicks the actual Message tab,
Drawing Canvas button, Settings tab, and All Device Controls button. Both real
scene windows must appear. Existing runner authorization was sufficient on Nova;
the harness does not grant permissions. The test terminates only its own app.
The script supplies and cleans a unique defaults suite even on test failure.
The `.xcresult` and runner log are retained under the printed artifact path.
The UI test also opens and cancels the native upload panel, stages a temporary
fixture archive without installation, runs the real app-local Arcade input
panel, sends a synthetic Escape, and verifies frame uploads stop. It reads the
mock HTTP status response, cancels its native save panel, then saves into the
script-owned temporary directory and verifies byte-exact output. It also selects
the binary asset-upload control, cancels and then chooses the temporary archive
through its native file panel, and verifies selection submits no upload. The
saved response is removed after verification. Live Stream is
never selected: URLProtocol isolation does not promise WebSocket interception.
The UI test presses the actual Quit button on success to flush an app-process
LLVM profile. The script requires nonempty ui-app profiles and merges them.
Use those profiles with the exact normal test binary for gate exports; never
substitute the acceptance binary's conditional-source denominator.

## Normal production startup proof

`BARKEEP_ACCEPTANCE_NORMAL=1 python3 scripts/test-app-acceptance.py` builds only
production sources, with DEBUG but without BARKEEP_APP_ACCEPTANCE. It exercises
the real default factory and services. A unique test bundle ID and process-only
NSArgumentDomain launch arguments select an ephemeral 127.0.0.1 HTTP fixture,
an empty token, and disabled automatic busy, calendar, notification forwarding,
ping, weather, and Slack features. No production app preferences are changed.
The local server records only methods/paths and fails unknown endpoints closed.
The parent closes its server and deletes only its own UUID suite/test bundle
preference domains in finally; it does not modify OS permission records.

This mode intentionally permits real CoreAudio activity metadata monitoring and
Bonjour discovery. It does not record audio or read calendar events or user
notifications. Unlike fixture mode, Bonjour is not mocked and may prompt for
local network consent. No UI interruption handler approves permissions; an
unexpected prompt is a blocker, not a reason to broaden permissions.

The XCUITest requires real controls and a status request received by the loopback
server. It also opens Live Device Status, enables a real URLSession WebSocket
against that same loopback server, receives a valid timestamp protobuf packet,
saves it through the default native exporter, checks exact JSON bytes in its
temporary directory, stops the stream, and quits normally. The bounded fixture
checks the enable message and stream close; no remote socket is used. The app
must flush a nonempty process coverage profile. The
normal-factory proof passed on Nova without any permission prompt. Its profile
showed execution of the real `return AppState()` factory line. Final coverage
must still use frozen identical source and export against the normal unit-test
production binary, never a union of multiple binaries' source denominators.

## Opt-in isolated Login Items acceptance

Run `BARKEEP_ACCEPTANCE_LOGIN=1 python3 scripts/test-app-acceptance.py` only
with explicit permission to temporarily register the isolated test app. A fresh
script-generated UUID bundle identity and matching identity file are required.
The real Settings checkbox registers once, requires actual SMAppService enabled
status, then unregisters and requires notRegistered. The initial notFound state
is allowed only for this fresh identity; it is not treated as registration denial.
No permission prompt is approved. RequiresApproval or registration errors stop
the test rather than triggering another registration attempt.

XCTest activities and a retained JSON attachment record the transition, without
requiring restricted runner filesystem writes. In finally, the parent launches
only the same isolated app with its exact expected bundle ID. That helper checks
actual status and unregisters only enabled/requiresApproval, then reports final
status. The app artifact is retained if cleanup is uncertain. The real BarKeep
service is never changed. On Nova the authorized test verified notFound → enabled
→ notRegistered, and independent cleanup observed notRegistered without another
mutation. Main-app registration worked from the temporary build directory using
ad-hoc signing; no Applications relocation or signing credentials were needed.
