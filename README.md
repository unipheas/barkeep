# BarKeep 👾

[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](https://www.apple.com/macos/)
[![Latest release](https://img.shields.io/github/v/release/unipheas/barkeep)](https://github.com/unipheas/barkeep/releases/latest)

A macOS menu bar companion for the [Busy Bar](https://busy.app) — control your bar over USB or Wi-Fi, automate your busy status, and turn the little LED display into a proper developer peripheral.

No cloud, no account, no telemetry: BarKeep talks directly to the bar's local HTTP API, either over USB (`http://10.0.4.20/api`, no authentication) or Wi-Fi (the bar's local IP address and local HTTP API password).

BarKeep is free and open-source software under the
[MIT License](LICENSE). You are welcome to use it, fork it, modify it,
redistribute it, or build your own project from it. Contributions are welcome.

## Features

**Menu bar app** (tabbed popover: Device / Message / Timers / Arcade / Settings)

- 🎙 **Auto On-Call** — flips the bar to *On Air* the moment any app opens your microphone (Teams, Zoom, FaceTime…), clears when the mic goes idle. Uses CoreAudio device state — no microphone permission needed, no audio ever captured.
- 📺 **Live preview** — see what's on the bar's display, right in the popover.
- 💬 **Messages** — send scrolling text in the bar's bitmap fonts, with a searchable full-emoji picker (emoji render to images on your Mac). Save presets, fire them in one click.
- 🎨 **Pixel canvas** — draw on a true-to-device 72×16 grid and send it to the display.
- 🍅 **Timers** — Pomodoro (work/rest/cycles) and simple countdowns, driven by the bar's native timer engine.
- 📅 **Calendar** — auto-busy during calendar events; one-click countdown-to-next-meeting on the bar.
- 🔔 **Notification forwarding** — scroll macOS notifications (Teams by default, any app by filter) across the bar with per-app LED colors, optional chime, and queue-during-calls replay.
- 🌐 **Ambient widgets** — live ping latency badge and local weather (icon + temperature) in the corners of the display.
- 🕹 **Busy Bar Arcade** — play Snake, Tetris, Pong, and Breakout on the
  physical 72×16 display using your Mac keyboard. The Mac preview is optional
  and off by default.
- 💤 **Slack sync** — bar goes busy → your Slack status becomes "🎧 On a call" + DND; clears after.
- ⚙️ Brightness/volume control, device rename, firmware update check, launch at login.

**Developer tools**

- 🖥 **`barkeep` CLI** — `barkeep send "build done" -c green`, `barkeep busy on -T coding`, `barkeep timer 45`, `barkeep pomodoro`… zero dependencies, scriptable from anything.
- 🤖 **Claude Code hooks** — the bar becomes your agent status light: green scroll + chime when a long task finishes, red flash when Claude waits on input.
- 🔌 **MCP server** — exposes the bar as tools (`bar_send_message`, `bar_set_busy`, `bar_start_timer`, …) so Claude, Codex, and ChatGPT desktop can drive it directly.

## Install

Requires macOS 14+ and a Busy Bar connected via USB or reachable on the same Wi-Fi network.

### Download

Grab `BarKeep-x.y.z.zip` from [Releases](https://github.com/unipheas/barkeep/releases), unzip, and move `BarKeep.app` to /Applications.

Release builds are signed with a Developer ID certificate and notarized by
Apple, so they open normally through Gatekeeper. If you'd rather build it
yourself, use the source instructions below.

### Homebrew

```bash
brew tap unipheas/barkeep
brew install --cask barkeep
```

Homebrew installs `BarKeep.app` directly into `/Applications`. To also install
the `barkeep` CLI, MCP server, and Claude Code hooks:

```bash
brew install barkeep-cli
```

When upgrading, quit the running menu-bar app first so macOS does not keep the
old executable in memory:

```bash
osascript -e 'quit app "BarKeep"' 2>/dev/null || true
brew upgrade --cask barkeep
open -a BarKeep
```

The running app version is shown at the bottom-right of its menu.

### Connect the Busy Bar

USB works at the fixed address `10.0.4.20` and does not require a password.
For Wi-Fi:

1. Open the Busy Bar's web interface and go to **Network → HTTP API**.
2. Enable HTTP API access and set its local numeric password.
3. In BarKeep → **Settings**, enter the bar's Wi-Fi IP address and that same
   password in **Wi-Fi password**.

The password is the one configured on the physical bar. Tokens created at
`cloud.busy.app` are for the cloud API and will be rejected by the local
device API.

### From source

```bash
git clone https://github.com/unipheas/barkeep.git
cd barkeep
./make-app.sh
```

This builds and launches `dist/BarKeep.app` (menu bar only, no Dock icon).
Signing prefers a Developer ID Application identity, then Apple Development,
or `$BARKEEP_SIGN_IDENTITY` when explicitly set; otherwise it falls back to
ad-hoc.

Optional extras:

```bash
ln -s "$PWD/bin/barkeep" /opt/homebrew/bin/barkeep      # CLI on PATH
claude mcp add --scope user barkeep -- /usr/bin/python3 "$PWD/mcp/barkeep_mcp.py"   # MCP server
```

Claude Code hooks: see [hooks/](hooks/) — wire them up in `~/.claude/settings.json` (`UserPromptSubmit` → `claude-prompt-submit.sh`, `Stop` → `claude-stop.sh`, `Notification` → `claude-notification.sh`).

### Codex and ChatGPT desktop

The ChatGPT desktop app, Codex CLI, and Codex IDE extension share local MCP
configuration. Install the developer tools, then register BarKeep:

```bash
brew install barkeep-cli
codex mcp add barkeep -- /usr/bin/python3 "$(brew --prefix barkeep-cli)/libexec/barkeep_mcp.py"
```

For a Busy Bar reached over Wi-Fi:

```bash
codex mcp add barkeep \
  --env BARKEEP_HOST=YOUR_BAR_IP \
  --env BARKEEP_TOKEN=YOUR_HTTP_API_PASSWORD \
  -- /usr/bin/python3 "$(brew --prefix barkeep-cli)/libexec/barkeep_mcp.py"
```

Restart ChatGPT desktop, Codex, or the IDE extension after adding the server.
Use `/mcp` to confirm that `barkeep` is connected.

To notify the Busy Bar whenever Codex or ChatGPT desktop finishes a turn and
waits for you, add this top-level setting to `~/.codex/config.toml`:

```toml
# Apple Silicon Homebrew
notify = ["/opt/homebrew/opt/barkeep-cli/share/barkeep-cli/hooks/codex-notify.sh"]
```

On an Intel Mac, use
`/usr/local/opt/barkeep-cli/share/barkeep-cli/hooks/codex-notify.sh` instead.
The notifier also forwards the event to Codex Computer Use when that helper is
installed. Restart Codex/ChatGPT desktop after changing the setting.

For permission-request signals and long-task timing, merge
[`hooks/codex-hooks.json`](hooks/codex-hooks.json) into
`~/.codex/hooks.json`, restart the app, then open `/hooks` and trust the three
BarKeep commands.

## Permissions

| Feature | Permission | Why |
|---|---|---|
| Busy Bar connection | Local Network | Required for the bar's local HTTP API over both its USB network interface and Wi-Fi. BarKeep asks on first launch. |
| Notification forwarding | Full Disk Access | macOS stores delivered notifications in a TCC-protected SQLite DB (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`). BarKeep polls it read-only; only titles/bodies matching your app filter are read, and they go straight to the bar over your local USB or Wi-Fi connection. |
| Calendar auto-busy | Calendar (full access) | To know when you're in an event. |
| Microphone detection | None | Mic detection reads CoreAudio device state, not audio. |

Grant Full Disk Access in System Settings → Privacy & Security → Full Disk
Access → add the installed `BarKeep.app`. Official release builds use a stable
Developer ID signature so the grant persists across upgrades. Locally rebuilt,
ad-hoc-signed copies may require the permission to be granted again.

## Slack setup

1. Create an app at https://api.slack.com/apps → *From scratch*
2. *OAuth & Permissions* → **User Token Scopes**: `users.profile:write`, `dnd:write`
3. *Install to Workspace*, copy the **User OAuth Token** (`xoxp-…`)
4. Paste into BarKeep → Settings → Slack

## Busy Bar Arcade

Open BarKeep → **Arcade**, then choose a game. BarKeep captures keyboard input
in a transparent input-only window, so the physical Busy Bar is the game
display and no game window needs to remain visible on the Mac.

| Key | Action |
|---|---|
| `1` / `2` / `3` / `4` | Switch to Snake / Tetris / Pong / Breakout |
| Arrow keys | Move (all games) |
| `W` / `S` | Alternate Pong controls |
| `↑` | Rotate a Tetris piece |
| `↓` | Soft-drop a Tetris piece |
| Space | Hard-drop a Tetris piece |
| `R` | Restart the current game |
| Escape | Stop the arcade and return keyboard focus to the previous Mac app |

Enable **Show preview in BarKeep** if you want a troubleshooting preview in
the Arcade tab. Games cannot run while a native busy/timer session is active,
because Busy Bar firmware rejects custom drawing during those sessions.
Starting an on-call session stops the arcade automatically.

If another Mac app takes keyboard focus, the game remains active on the Busy
Bar. Return to the Arcade tab and click **Capture Keyboard** to resume controls.

## Configuration

Everything is configured in the app's Settings tab — device host, local HTTP API password (needed for Wi-Fi), busy theme, notification filter, Slack token, ping target, weather unit and location (type a city, it's geocoded for you; leave empty for automatic IP-based location). No config files, no terminal required.

CLI env: `BARKEEP_HOST` (device address, default `10.0.4.20`),
`BARKEEP_TOKEN` (the local HTTP API password for Wi-Fi), and
`BARKEEP_THEME` (busy theme, default `on_air`).

### Connection troubleshooting

- **Unreachable over USB:** reconnect the cable, wait a few seconds for the
  USB network interface, and leave the host set to `10.0.4.20`.
- **Unreachable over Wi-Fi:** confirm the Mac and Busy Bar can communicate on
  the same network. Guest networks and some phone hotspots isolate clients.
- **Token rejected / HTTP 403:** use the local numeric HTTP API password from
  the bar's own web interface, not a token from `cloud.busy.app`.
- **No Local Network prompt:** open System Settings → Privacy & Security →
  Local Network and enable BarKeep. If it is already enabled, toggle it off
  and back on, then relaunch BarKeep.
- **Pasted a full URL:** BarKeep accepts either an IP/hostname or a URL such as
  `http://busy-bar.local/login` and normalizes it to the device host.

## Device API notes

Verified against firmware 1.0.2 / API 24.3.0
([official local HTTP API docs](https://docs.busy.app/bar/dev/http-api)):

- Over USB the API is served at `http://10.0.4.20/api/*` with no authentication. Over Wi-Fi, enable HTTP API access in the bar's local web interface, configure its numeric password, then enter that same password in BarKeep Settings. BarKeep sends it using the firmware API's documented `X-API-Token` header. API tokens generated at `cloud.busy.app` are for the internet API and do not authenticate requests to a local IP address. The docs' `/busybar/*` prefix is for the cloud proxy; BarKeep communicates with the device locally.
- Text elements accept printable ASCII only (bitmap fonts); BarKeep renders emoji/unicode to PNGs and uploads them as assets.
- `/api/screen` returns base64 of raw **GRB** pixel data (LED byte order), 72×16×3.
- The firmware rejects *all* draw requests while a busy session is active, regardless of priority.
- Busy themes are directories on device storage (`/ext/apps_assets/busy/themes`) — BarKeep discovers them dynamically.
- Notification DB `rec_id`s are recycled after deletions; BarKeep diffs by notification UUID.

## Development

```bash
swift test             # run the test suite
swift build            # debug build
./make-app.sh          # signed release build + launch
```

The icon is generated: `cd assets && swift gen_icon.swift 1024 icon.png` (see `gen_icon.swift` for the pixel grid).

## Contributing

Bug reports, feature ideas, documentation improvements, code contributions,
and personal forks are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development workflow and pull-request checklist.

Please report potential vulnerabilities privately using
[GitHub's security advisory form](https://github.com/unipheas/barkeep/security/advisories/new);
see [SECURITY.md](SECURITY.md) for details.

## License

BarKeep is released under the [MIT License](LICENSE). In practical terms, you
may use, copy, modify, merge, publish, distribute, sublicense, and sell copies
of the software. Keep the copyright and license notice with copies or
substantial portions of the project.

Contributions submitted to this repository are licensed under the same MIT
terms.

Not affiliated with Busy Inc. Busy Bar is a product of https://busy.app.
