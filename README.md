# BarKeep 👾

A macOS menu bar companion for the [Busy Bar](https://busy.app) — control your bar over USB or Wi-Fi, automate your busy status, and turn the little LED display into a proper developer peripheral.

No cloud, no account, no telemetry: BarKeep talks directly to the bar's local HTTP API, either over USB (`http://10.0.4.20/api`, no authentication) or Wi-Fi (the bar's local IP address and API token).

## Features

**Menu bar app** (tabbed popover: Device / Message / Timers / Settings)

- 🎙 **Auto On-Call** — flips the bar to *On Air* the moment any app opens your microphone (Teams, Zoom, FaceTime…), clears when the mic goes idle. Uses CoreAudio device state — no microphone permission needed, no audio ever captured.
- 📺 **Live preview** — see what's on the bar's display, right in the popover.
- 💬 **Messages** — send scrolling text in the bar's bitmap fonts, with a searchable full-emoji picker (emoji render to images on your Mac). Save presets, fire them in one click.
- 🎨 **Pixel canvas** — draw on a true-to-device 72×16 grid and send it to the display.
- 🍅 **Timers** — Pomodoro (work/rest/cycles) and simple countdowns, driven by the bar's native timer engine.
- 📅 **Calendar** — auto-busy during calendar events; one-click countdown-to-next-meeting on the bar.
- 🔔 **Notification forwarding** — scroll macOS notifications (Teams by default, any app by filter) across the bar with per-app LED colors, optional chime, and queue-during-calls replay.
- 🌐 **Ambient widgets** — live ping latency badge and local weather (icon + temperature) in the corners of the display.
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

BarKeep is open source and not notarized (no paid Apple Developer account), so macOS warns on first launch: right-click the app → **Open** → **Open**, or run `xattr -dr com.apple.quarantine /Applications/BarKeep.app`. If you'd rather build it yourself, use the source instructions below.

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

### From source

```bash
git clone https://github.com/unipheas/barkeep.git
cd barkeep
./make-app.sh
```

This builds and launches `dist/BarKeep.app` (menu bar only, no Dock icon). Signing uses your first Apple Development identity if you have one, `$BARKEEP_SIGN_IDENTITY` if set, or falls back to ad-hoc.

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
  --env BARKEEP_TOKEN=YOUR_API_TOKEN \
  -- /usr/bin/python3 "$(brew --prefix barkeep-cli)/libexec/barkeep_mcp.py"
```

Restart ChatGPT desktop, Codex, or the IDE extension after adding the server.
Use `/mcp` to confirm that `barkeep` is connected.

For the same automatic task-finished and needs-input signals as Claude Code,
merge [`hooks/codex-hooks.json`](hooks/codex-hooks.json) into
`~/.codex/hooks.json`, restart Codex/ChatGPT desktop, then open `/hooks` and
trust the three BarKeep commands. Codex and ChatGPT desktop share these hooks.

## Permissions

| Feature | Permission | Why |
|---|---|---|
| Notification forwarding | Full Disk Access | macOS stores delivered notifications in a TCC-protected SQLite DB (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`). BarKeep polls it read-only; only titles/bodies matching your app filter are read, and they go straight to the bar over your local USB or Wi-Fi connection. |
| Calendar auto-busy | Calendar (full access) | To know when you're in an event. |
| Everything else | none | Mic detection reads CoreAudio device state, not audio. |

Grant Full Disk Access in System Settings → Privacy & Security → Full Disk Access → add the installed `BarKeep.app`. **Note:** macOS ties the grant to the app's code signature — with ad-hoc signing you may need to re-grant after rebuilding or upgrading; with a real identity it sticks.

## Slack setup

1. Create an app at https://api.slack.com/apps → *From scratch*
2. *OAuth & Permissions* → **User Token Scopes**: `users.profile:write`, `dnd:write`
3. *Install to Workspace*, copy the **User OAuth Token** (`xoxp-…`)
4. Paste into BarKeep → Settings → Slack

## Configuration

Everything is configured in the app's Settings tab — device host, API token (needed for Wi-Fi), busy theme, notification filter, Slack token, ping target, weather unit and location (type a city, it's geocoded for you; leave empty for automatic IP-based location). No config files, no terminal required.

CLI env: `BARKEEP_HOST` (device address, default `10.0.4.20`), `BARKEEP_THEME` (busy theme, default `on_air`).

## Device API notes

Verified against firmware 1.0.2 / API 24.3.0 ([official docs](https://api.busy.app/busybar/docs)):

- Over USB the API is served at `http://10.0.4.20/api/*` with no authentication. Over Wi-Fi, enter the bar's local IP address and bearer token in Settings. The docs' `/busybar/*` prefix is for the cloud proxy; BarKeep communicates with the device locally.
- Text elements accept printable ASCII only (bitmap fonts); BarKeep renders emoji/unicode to PNGs and uploads them as assets.
- `/api/screen` returns base64 of raw **GRB** pixel data (LED byte order), 72×16×3.
- The firmware rejects *all* draw requests while a busy session is active, regardless of priority.
- Busy themes are directories on device storage (`/ext/apps_assets/busy/themes`) — BarKeep discovers them dynamically.
- Notification DB `rec_id`s are recycled after deletions; BarKeep diffs by notification UUID.

## Development

```bash
swift build            # debug build
./make-app.sh          # release build + launch
```

The icon is generated: `cd assets && swift gen_icon.swift 1024 icon.png` (see `gen_icon.swift` for the pixel grid).

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Busy Inc. Busy Bar is a product of https://busy.app.
