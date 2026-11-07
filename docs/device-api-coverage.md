# Busy Bar firmware 1.3.1 support

BarKeep's generated catalog comes from the connected device's OpenAPI 27.14.0
specification (`http://10.0.4.20/openapi.yaml`), retrieved November 7, 2026.
It contains 81 operations across 62 paths. Regenerate with
`scripts/generate-api-catalog.py` using PyYAML and a saved firmware specification.
The generator resolves parameter and request-body references and preserves field
reference text and examples. Firmware remains the final authority on validity.

## User-facing controls

- Apps: list, package upload/stage/review/install, launch, stop, remove, read/write/reset
  settings. Schemas provide native checkbox, integer, enum, text and grouped fields;
  advanced JSON preserves the full document and supports other field types.
- Settings → All Device Controls: searchable native access to the local HTTP API,
  with parameter fields, JSON bodies, binary upload and response export. Includes
  Wi-Fi, BLE, access tokens, device/account/Matter settings, busy profiles, input,
  storage, time, display, audio and firmware updates.
- `/status/ws` opens a native live status inspector. It starts/stops the stream,
  decodes the vendor's protobuf schema, and exports the latest packet as JSON.
  Embedded image/timer bytes are preserved as Base64. The Device preview polls
  `/screen`. The read-only hardware test is `BARKEEP_LIVE_STATUS=1 swift test
  --filter StatusStreamTests/testLiveStatusStreamOnConnectedDevice`.
- Launching a JS app waits for Arcade uploads to finish, clears BarKeep's display
  layer, and pauses ambient widgets without changing saved preferences. Stop or
  Device → Resume restores widgets.
- CLI: `barkeep apps` and `barkeep api`; MCP: dedicated app tools plus local API
  read/write tools. Building JS source uses official Busy Tools; BarKeep accepts
  its built packages without requiring Busy's desktop app.
- Teams uses microphone activity and Notification Center forwarding. Microsoft
  Graph presence synchronization is intentionally outside the agreed scope.
- Slack uses the existing opt-in user-token status/DND integration. Tests use
  mock Slack responses, never change a real workspace's status.

## Release gates

The requested 100% whole-app coverage is a release gate, not a claim made by the
current implementation. `scripts/check-coverage.py` reports all production Swift
sources without excluding UI or OS integrations. Release-tag CI requires 100%.
Python MCP/CLI/agent-hook coverage is enforced separately at 100% statement coverage.
Native view layout tests do not replace interactive UI testing. Rendering tools
cannot render all AppKit-backed controls offscreen, so their images alone are
not evidence of complete UI correctness.

The opt-in hardware test is `BARKEEP_TEST_PACKAGE=/path/to/app.barkeep.qa.tgz
swift test --filter LiveDeviceTests`. It refuses to replace an existing app of
that ID or interrupt a native busy session. It checks stage/install/list/settings/
launch/display/stop/remove and verifies the original app IDs remain. The package
must be built with the official Node 24 Busy Tools workflow. Only the disposable
QA app is changed; its retained settings may remain on device storage.

Sources: https://docs.busy.app/bar/dev/js-apps,
https://github.com/busy-app/busy-tools,
https://github.com/busy-app/busylib-ts,
https://github.com/busy-app/busybar-firmware/blob/dev/applications_js/AGENTS.md.

## Interactive checks (November 7, 2026)

The development build's controls window was exercised on macOS against the
connected USB bar: list, stage/review/install the disposable QA package, edit
native settings, inspect advanced JSON, reset, run, verify live screen, stop,
and remove. The original three apps remained installed. Device, Message,
Timers, Arcade and Settings layouts were inspected. All Device Controls search,
status read and required-field validation were exercised. Full UI validation
remains ongoing; this is not a blanket claim that every interaction passed.

The CLI entry point is also tested against a local HTTP fixture. Agent-hook
tests use private temporary state and mocked delivery; no real Slack status,
agent notification, or personal calendar data is used by the unit suite.

A second pass exercised live status start/stop/export, rejected an empty required
parameter before confirmation, set/read/restored brightness, sent a text message,
started/ended both timer types, and started Arcade then returned with Escape.
With ping enabled, launching the disposable JS app paused the widget; removing
that app resumed it. The test package was removed, ping and Arcade preview were
returned to their original off state, and smart-home triggering and the native
idle busy snapshot were restored. No existing device apps were removed.

Fast drawing drags revealed missing pixels between input samples, now fixed by
connecting samples. A red drawing revealed that screen bytes were interpreted
as GRB instead of the vendor's BGR; the preview now uses BGR and rear-screen L4
frames are expanded correctly. Regression tests check both formats. The live
retest showed a continuous red stroke matching the canvas. Emoji search,
rendered-image delivery, and temporary preset creation/removal also passed.

The expanded QA schema was also tested through the native editor: boolean,
integer, enum, color, time and nested string changes were saved and verified by
reading them back from the device. Reset restored every default. Invalid values
now receive field-specific validation before upload (including integer bounds,
UTF-8 string byte lengths, enum options, color/time formats and schema version).
Unsupported future field types remain available through Advanced JSON.

Package upload accepts up to 100 MiB, matching `MAX_UPLOAD_FILE_SIZE` in the
vendor's `applications/services/web_server/http_api/api_apps.c`. Native controls
and the CLI use the same limit. The settings validation follows the vendor's
[settings schema](https://developer.busy.app/javascript-applications-settings-schema.html).

Repeatable control-action tests also exercise app refresh/run/stop, preset send/
remove, busy/timer buttons, USB/Wi-Fi switching, brightness, volume, preference
persistence and native schema bindings. ViewInspector is pinned as a test-only
dependency; these tests inspect observable and binding-backed actions. They do
not replace live testing of SwiftUI-owned state, system dialogs or AppKit focus.
Local-network permission lifecycle tests use a fake browser to check duplicate
requests, failure/cancellation cleanup and callbacks from an obsolete probe.
