# BarKeep 1.1.0

## New

- Manage Busy Bar JavaScript apps: upload, inspect, install, launch, stop, remove,
  and edit or reset app settings directly from the Mac. Requires firmware 1.3.1+.
- Native settings forms support grouped fields, booleans, integers, options,
  colors, time and strings; Advanced JSON preserves the complete document.
- Search all 81 local API operations in All Device Controls, with reviewed
  writes, file uploads, response export and decoded live status streaming.
- Manage apps and device settings through the CLI and 16 MCP tools.
- Agent hooks handle overlapping runs and install alongside the CLI.

## Fixed

- Device app launches pause ambient widgets and wait for Arcade uploads.
- Screen previews decode front BGR and rear L4 frames correctly.
- Fast canvas strokes connect input samples without leaving gaps.
- Volume writes use the numeric silent flag required by firmware 1.3.1.
- Brightness, volume, busy and timer changes reject stale status responses.
- Busy transitions serialize device and Slack changes; switching devices
  discards queued writes for the previous connection.
- Notification queues remain bound to their original device.
- Calendar changes with unchanged event IDs refresh correctly.
- Non-RGB colors fall back safely instead of raising a conversion exception.
- Missing device/request URLs reject before transport.
- Cancelled Arcade uploads are not counted as connection failures.

## Validation and limits

The local whole-source gate passed **7,913/7,913 production Swift lines (100%)**
on Xcode 27.2, combining 194 passing tests and four successful native acceptance
modes. Every production Swift file remains included. The two opt-in physical
tests were skipped on Nova; earlier MacBook USB firmware 1.3.1 app lifecycle and
stream tests passed separately. Python MCP/CLI/hooks passed 15 tests with
**385/385 production statements (100%)**.

Native acceptance verifies startup/quit, actual file panels, Canvas output,
Arcade focus/cancellation, loopback WebSocket decoding and native export, and
isolated Login Items registration/removal with verified cleanup. Simulated
platform failure tests verify error handling, not an actual OS failure. See
[app-acceptance-testing.md](app-acceptance-testing.md) and
[device-api-coverage.md](device-api-coverage.md) for scope and limitations.

Teams uses microphone detection and Notification Center forwarding; Graph
presence sync is not included. Slack and calendar automation use controlled
fixtures in the automated suite, not live personal accounts.

Firmware 1.3.1 may acknowledge app Stop before its script is released. A rapid
Remove can fail with HTTP 508 and leave partial files. BarKeep reconciles the
app list and displays that failure rather than reporting success.
