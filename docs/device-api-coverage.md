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
- `/status/ws` is listed as a WebSocket endpoint, not sent as an ordinary HTTP
  request. The existing Device preview polls `/screen`. A decoded live WebSocket
  status inspector is not implemented.
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
Python MCP/CLI coverage is enforced separately at 100% statement coverage.
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
