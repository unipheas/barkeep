# BarKeep 1.1.0 — release candidate

Not published. The requested 100% Swift coverage gate remains unmet.

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

## Validation and limits

120 Swift tests passed on November 7, 2026, including the opt-in physical-device
app lifecycle and status stream tests. Whole-source Swift line coverage from
that run was 85.60% (6,712/7,841). The last Python coverage run covered all
385 production statements across MCP/CLI and hooks. Native UI checks are
detailed in [device-api-coverage.md](device-api-coverage.md).

Teams uses microphone detection and Notification Center forwarding; Graph
presence sync is not included. Slack and calendar automation use controlled
fixtures in the automated suite, not live personal accounts.

Firmware 1.3.1 may acknowledge app Stop before its script is released. A rapid
Remove can fail with HTTP 508 and leave partial files. BarKeep reconciles the
app list and displays that failure rather than reporting success.

This candidate is not a 100%-coverage or issue-free production certification.
Do not publish until the outstanding release requirement is resolved.
