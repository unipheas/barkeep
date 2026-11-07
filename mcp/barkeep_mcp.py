#!/usr/bin/env python3
"""Zero-dependency MCP stdio server exposing the Busy Bar's local HTTP API.

Tools include messaging, busy sessions, app management, and local device API access.
Host defaults to the USB address (10.0.4.20); override with BARKEEP_HOST.
For Wi-Fi, BARKEEP_TOKEN is the local HTTP API password configured on the bar,
not a cloud.busy.app API token.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
import re
from pathlib import Path

HOST = os.environ.get("BARKEEP_HOST", "10.0.4.20")
TOKEN = os.environ.get("BARKEEP_TOKEN", "")
def normalized_host(value):
    parsed = urllib.parse.urlsplit(value if "://" in value else "http://" + value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("Use a local device hostname or IP address")
    host = parsed.hostname
    if ":" in host:
        host = "[" + host + "]"
    return host + (":" + str(parsed.port) if parsed.port else "")

API = f"http://{normalized_host(HOST)}/api"

COLORS = {
    "white": "#FFFFFFFF", "red": "#FF3B30FF", "green": "#34C759FF",
    "blue": "#0A84FFFF", "yellow": "#FFD60AFF", "orange": "#FF9500FF",
    "purple": "#BF5AF2FF", "cyan": "#32ADE6FF", "pink": "#FF2D55FF",
}

TOOLS = [
    {
        "name": "bar_send_message",
        "description": "Scroll a text message across the Busy Bar's front LED display. "
                       "ASCII only (the device uses bitmap fonts). This can temporarily cover "
                       "the current device screen, including a busy session.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string", "description": "Message to display (ASCII)"},
                "color": {"type": "string", "description": "Color name (white/red/green/blue/yellow/orange/purple/cyan/pink) or #RRGGBBAA", "default": "white"},
                "seconds": {"type": "integer", "description": "How long to show it; 0 = until cleared", "default": 30},
                "chime": {"type": "boolean", "description": "Also play a chime on the bar", "default": False},
            },
            "required": ["text"],
        },
    },
    {
        "name": "bar_set_busy",
        "description": "Turn the Busy Bar's busy state on or off (shows a theme like 'on_air', "
                       "'coding', 'dnd' and triggers smart home). Use for do-not-disturb signaling.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "on": {"type": "boolean"},
                "theme": {"type": "string", "description": "Theme when on: busy, on_air, on_call, coding, dnd, meeting, lunch, flow, keep_out, booked, back_soon, chill_time, low_social_battery", "default": "on_air"},
            },
            "required": ["on"],
        },
    },
    {
        "name": "bar_start_timer",
        "description": "Start a countdown busy session on the Busy Bar for N minutes (device shows remaining time).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "minutes": {"type": "integer", "minimum": 1, "maximum": 480},
                "theme": {"type": "string", "default": "on_air"},
            },
            "required": ["minutes"],
        },
    },
    {
        "name": "bar_clear",
        "description": "Clear any messages/drawings this integration put on the Busy Bar display.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "bar_status",
        "description": "Get the Busy Bar's current status: battery, firmware, busy state, transport.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


_APP_ID = {"type": "string", "description": "Installed app ID, e.g. app.busy.clock"}

def tool(name, description, properties=None, required=None, read=False):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {}, "required": required or [], "additionalProperties": False},
            "annotations": {"readOnlyHint": read, "destructiveHint": not read, "openWorldHint": False}}

TOOLS += [
    tool("bar_apps_list", "List installed JS apps. Requires firmware 1.3.1+.", read=True),
    tool("bar_app_stage", "Upload and validate a local .tgz/.tar app package. Returns app details and a single-use install_key; does not install or launch it.", {"path": {"type": "string"}}, ["path"]),
    tool("bar_app_install", "Install the staged app using its single-use install_key. Replaces an existing version. Only when the user requests installation.", {"install_key": {"type": "integer", "minimum": 0, "maximum": 4294967295}}, ["install_key"]),
    tool("bar_app_launch", "Launch an installed app on the bar when requested.", {"app_id": _APP_ID}, ["app_id"]),
    tool("bar_app_stop", "Stop the running JS app when requested."),
    tool("bar_app_remove", "Remove an installed app when requested; retains its saved settings.", {"app_id": _APP_ID}, ["app_id"]),
    tool("bar_app_settings_get", "Read an app's complete settings document.", {"app_id": _APP_ID}, ["app_id"], read=True),
    tool("bar_app_settings_set", "Replace the complete app settings document when requested. Include its version and every value.", {"app_id": _APP_ID, "settings": {"type": "object"}}, ["app_id", "settings"]),
    tool("bar_app_settings_reset", "Reset app settings to defaults when requested.", {"app_id": _APP_ID}, ["app_id"]),
    tool("bar_api_read", "Read a local device API endpoint. Supply a path like /wifi/status; query parameters are separate. No remote URLs.", {"path": {"type": "string"}, "query": {"type": "object"}}, ["path"], read=True),
    tool("bar_api_write", "Change a local device API setting only when the user requests that specific action. Supports network, Bluetooth, Matter, time, firmware, input and other documented controls.", {"method": {"type": "string", "enum": ["POST", "PUT", "DELETE"]}, "path": {"type": "string"}, "query": {"type": "object"}, "body": {"type": "object"}}, ["method", "path"]),
]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(method, path, body=None, query=None, raw=None, timeout=8, binary=False):
    if method not in ("GET", "POST", "PUT", "DELETE", "PATCH"):
        raise ValueError("Invalid HTTP method")
    if not path.startswith("/") or path.startswith("//") or any(x in path for x in ("..", "?", "#", "://")):
        raise ValueError("Use a local API path beginning with /, without a query string")
    if any(ord(c) < 32 or ord(c) == 127 for c in TOKEN):
        raise ValueError("BARKEEP_TOKEN contains control characters")
    url = API + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = raw if raw is not None else json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/octet-stream" if raw is not None else "application/json")
    if TOKEN:
        req.add_header("X-API-Token", TOKEN)
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=timeout) as resp:
            result = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read(1000).decode(errors="replace")
        raise ValueError(f"HTTP {exc.code} {path}: {detail}") from exc
    if binary:
        return result
    if not result:
        return {}
    try:
        return json.loads(result)
    except (ValueError, UnicodeDecodeError):
        return {"text": result.decode(errors="replace")}


def app_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,31}", value):
        raise ValueError("Invalid Busy Bar app ID")
    return value


def package_bytes(path):
    file = Path(path).expanduser()
    if file.suffix.lower() not in (".tgz", ".tar", ".gz"):
        raise ValueError("Choose a .tgz or .tar app package")
    if not 0 < file.stat().st_size <= 100 * 1024 * 1024:
        raise ValueError("App package must contain 1 byte to 100 MiB")
    return file.read_bytes()


def settings_document(value):
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] < 1 or not isinstance(value.get("values"), dict):
        raise ValueError("Settings require an integer version and a values object")
    return value


def integer(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} must be an integer from {low} to {high}")
    return value


def bar_settings(theme):
    return {"theme": theme, "show_work_phase_only": False, "trigger_smart_home": True}


def put_snapshot(snapshot):
    return api("PUT", "/busy/snapshot", {
        "snapshot": snapshot,
        "snapshot_timestamp_ms": int(time.time() * 1000),
    })


def color_hex(value):
    if value.startswith("#"):
        return value
    return COLORS.get(value.lower(), "#FFFFFFFF")


def handle_tool(name, args):
    if not isinstance(args, dict):
        raise ValueError("Tool arguments must be an object")
    if name == "bar_apps_list":
        return json.dumps(api("GET", "/apps/list"))
    if name == "bar_app_stage":
        return json.dumps(api("POST", "/apps/stage", raw=package_bytes(args["path"]), timeout=120))
    if name == "bar_app_install":
        key = integer(args["install_key"], 0, 4294967295, "install_key")
        return json.dumps(api("POST", "/apps/install", query={"install_key": key}, timeout=120))
    if name == "bar_app_stop":
        return json.dumps(api("POST", "/apps/quit"))
    if name in ("bar_app_launch", "bar_app_remove", "bar_app_settings_get", "bar_app_settings_set", "bar_app_settings_reset"):
        query = {"app_id": app_id(args["app_id"])}
        method, path = {
            "bar_app_launch": ("POST", "/apps/launch"), "bar_app_remove": ("DELETE", "/apps"),
            "bar_app_settings_get": ("GET", "/apps/settings"), "bar_app_settings_set": ("PUT", "/apps/settings"),
            "bar_app_settings_reset": ("DELETE", "/apps/settings")}[name]
        body = settings_document(args["settings"]) if name == "bar_app_settings_set" else None
        return json.dumps(api(method, path, query=query, body=body))
    if name in ("bar_api_read", "bar_api_write"):
        method = "GET" if name == "bar_api_read" else args["method"]
        if name == "bar_api_write" and method not in ("POST", "PUT", "DELETE"):
            raise ValueError("Write method must be POST, PUT or DELETE")
        return json.dumps(api(method, args["path"], query=args.get("query"), body=args.get("body"), timeout=120))
    if name == "bar_send_message":
        integer(args.get("seconds", 30), 0, 86400, "seconds")
        text = "".join(c for c in args["text"] if 0x20 <= ord(c) <= 0x7E).strip()
        if not text:
            return "Message was empty after removing non-ASCII characters."
        api("POST", "/display/draw", {
            "application_name": "busybar_mcp",
            "priority": 95,
            "elements": [{
                "id": "mcp", "type": "text", "text": text,
                "font": "normal", "color": color_hex(args.get("color", "white")),
                "align": "mid_left", "x": 0, "y": 8, "width": 72,
                "scroll_rate": 2500, "scroll_start_delay": 800,
                "scroll_repeat_delay": 1500,
                "timeout": args.get("seconds", 30), "display": "front",
            }],
        })
        if args.get("chime"):
            api("POST", "/audio/play", {"application_name": "busybar_mcp",
                                        "stock_path": "shared/calendar_event_starts.snd"})
        return f"Displayed: {text}"

    if name == "bar_set_busy":
        if type(args["on"]) is not bool:
            raise ValueError("on must be a boolean")
        if args["on"]:
            put_snapshot({
                "type": "INFINITE",
                "card_id": "00000000-0000-0000-0000-000000000000",
                "is_paused": False,
                "busy_bar_settings": bar_settings(args.get("theme", "on_air")),
            })
            return f"Busy ON with theme {args.get('theme', 'on_air')}"
        put_snapshot({"type": "NOT_STARTED", "busy_bar_settings": bar_settings("busy")})
        return "Busy OFF"

    if name == "bar_start_timer":
        integer(args["minutes"], 1, 480, "minutes")
        put_snapshot({
            "type": "SIMPLE",
            "card_id": "00000000-0000-0000-0000-000000000000",
            "time_left_ms": args["minutes"] * 60000,
            "is_paused": False,
            "busy_bar_settings": bar_settings(args.get("theme", "on_air")),
        })
        return f"Timer started: {args['minutes']} minutes"

    if name == "bar_clear":
        failures = []
        for app in ("busybar_mcp", "busybar_cli", "busybar_mac"):
            try:
                api("DELETE", "/display/draw", query={"application_name": app})
            except Exception as exc:
                failures.append(str(exc))
        if failures:
            raise ValueError("Could not clear all displays: " + "; ".join(failures))
        return "Display cleared"

    if name == "bar_status":
        status = api("GET", "/status")
        busy = api("GET", "/busy/snapshot")
        return json.dumps({
            "battery": status.get("power", {}).get("battery_charge"),
            "power_state": status.get("power", {}).get("state"),
            "firmware": status.get("firmware", {}).get("version"),
            "busy_state": busy.get("snapshot", {}).get("type"),
            "theme": busy.get("snapshot", {}).get("busy_bar_settings", {}).get("theme"),
        })

    raise ValueError(f"unknown tool {name}")


def reply(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply(None, error={"code": -32700, "message": "Parse error"})
            continue
        if (not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0"
                or not isinstance(msg.get("method"), str)
                or ("id" in msg and type(msg["id"]) not in (int, str))):
            reply(None, error={"code": -32600, "message": "Invalid Request"})
            continue
        method = msg.get("method")
        msg_id = msg.get("id")
        # Notifications must never produce responses or execute tool mutations.
        if "id" not in msg:
            continue
        params = msg.get("params", {})
        if not isinstance(params, dict):
            reply(msg_id, error={"code": -32602, "message": "params must be an object"})
            continue

        if method == "initialize":
            reply(msg_id, {
                "protocolVersion": (params.get("protocolVersion") if params.get("protocolVersion") in
                    ("2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25") else "2025-11-25"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "barkeep", "version": "1.1.0"},
                "instructions": "Use these tools when the user asks to control or inspect their Busy Bar. "
                                "Do not change busy state, start timers, clear the display, or send "
                                "messages unless the user requests that action.",
            })
        elif method == "tools/list":
            reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            try:
                text = handle_tool(params.get("name"), params.get("arguments", {}))
                reply(msg_id, {"content": [{"type": "text", "text": text}]})
            except Exception as exc:
                reply(msg_id, {"content": [{"type": "text", "text": f"Error: {exc}"}],
                               "isError": True})
        elif method == "ping":
            reply(msg_id, {})
        else:
            reply(msg_id, error={"code": -32601, "message": f"method not found: {method}"})


def cli_color(value):
    if value.lower() in COLORS:
        return COLORS[value.lower()]
    if re.fullmatch(r"#[0-9A-Fa-f]{8}", value):
        return value
    raise ValueError("Use a color name or #RRGGBBAA")


def run_cli_control(args):
    theme = getattr(args, "theme", os.environ.get("BARKEEP_THEME", "on_air"))
    if not re.fullmatch(r"[A-Za-z0-9_-]+", theme):
        raise ValueError("Invalid theme name")
    if args.command == "send":
        seconds = integer(args.seconds, 0, 86400, "seconds")
        text = "".join(c for c in args.text if 0x20 <= ord(c) <= 0x7E)
        if not text.strip():
            raise ValueError("Message is empty after removing non-ASCII characters")
        payload = {"application_name": "busybar_cli", "priority": 95, "elements": [{
            "id":"cli", "type":"text", "text":text, "font":args.font,
            "color":cli_color(args.color), "align":"mid_left", "x":0, "y":8, "width":72,
            "scroll_rate":2500, "scroll_start_delay":800, "scroll_repeat_delay":1500,
            "timeout":seconds, "display":"front"}]}
        if args.led:
            payload["led_notification_color"] = cli_color(args.led)
        api("POST", "/display/draw", payload)
    elif args.command == "busy":
        handle_tool("bar_set_busy", {"on":args.state == "on", "theme":theme})
    elif args.command == "timer":
        handle_tool("bar_start_timer", {"minutes":args.minutes, "theme":theme})
    elif args.command == "pomodoro":
        work = integer(args.work, 1, 480, "work minutes") * 60000
        rest = integer(args.rest, 1, 480, "rest minutes") * 60000
        cycles = integer(args.cycles, 1, 100, "cycles")
        put_snapshot({"type":"INTERVAL", "card_id":"00000000-0000-0000-0000-000000000000",
            "current_interval":1, "current_interval_time_total_ms":work,
            "current_interval_time_left_ms":work, "is_paused":False,
            "interval_settings":{"type":"INTERVAL", "interval_work_ms":work, "interval_rest_ms":rest,
                "interval_work_cycles_count":cycles, "is_autostart_enabled":False},
            "busy_bar_settings":bar_settings(theme)})
    elif args.command == "clear":
        for app in ("busybar_cli", "busybar_mac"):
            api("DELETE", "/display/draw", query={"application_name":app})
    elif args.command == "sound":
        api("POST", "/audio/play", {"application_name":"busybar_cli", "stock_path":"shared/calendar_event_starts.snd"})
    elif args.command == "status":
        print(json.dumps(api("GET", "/status"), indent=2))
        print(json.dumps(api("GET", "/busy/snapshot"), indent=2))


def cli(argv):
    import argparse
    parser = argparse.ArgumentParser(prog="barkeep", description="Busy Bar app management and local API access")
    commands = parser.add_subparsers(dest="command", required=True)
    send = commands.add_parser("send", help="Show a message on the bar")
    send.add_argument("text")
    send.add_argument("-c", "--color", default="white")
    send.add_argument("-f", "--font", choices=["tiny","small","normal","condensed","bold","large","extra_large"], default="normal")
    send.add_argument("-t", "--seconds", type=int, default=30)
    send.add_argument("-l", "--led")
    busy = commands.add_parser("busy", help="Set busy state")
    busy.add_argument("state", choices=["on", "off"], nargs="?", default="on")
    busy.add_argument("-T", "--theme", default=os.environ.get("BARKEEP_THEME", "on_air"))
    timer = commands.add_parser("timer", help="Start a countdown")
    timer.add_argument("minutes", type=int)
    pomodoro = commands.add_parser("pomodoro", help="Start an interval session")
    pomodoro.add_argument("work", type=int, nargs="?", default=25)
    pomodoro.add_argument("rest", type=int, nargs="?", default=5)
    pomodoro.add_argument("cycles", type=int, nargs="?", default=4)
    for name in ("clear", "sound", "status"):
        commands.add_parser(name)
    apps = commands.add_parser("apps", aliases=["app"])
    actions = apps.add_subparsers(dest="action", required=True)
    actions.add_parser("list")
    install = actions.add_parser("install")
    install.add_argument("path", help="Built .tgz or .tar package")
    for name in ("run", "remove", "settings", "reset-settings"):
        p = actions.add_parser(name)
        p.add_argument("app_id")
    save = actions.add_parser("set-settings")
    save.add_argument("app_id"); save.add_argument("file", help="Complete settings JSON file")
    actions.add_parser("stop")
    request = commands.add_parser("api")
    request.add_argument("method", choices=["GET", "POST", "PUT", "DELETE"])
    request.add_argument("path")
    request.add_argument("--query", default="{}", help="Query parameters as a JSON object")
    request.add_argument("--json", help="Request JSON object")
    request.add_argument("--file", help="Binary file to upload")
    request.add_argument("--output", help="Write response bytes to this local file")
    args = parser.parse_args(argv)
    try:
        if args.command in ("send", "busy", "timer", "pomodoro", "clear", "sound", "status"):
            run_cli_control(args)
            return 0
        if args.command == "api":
            if args.json is not None and args.file:
                raise ValueError("Use --json or --file, not both")
            query = json.loads(args.query)
            if not isinstance(query, dict): raise ValueError("--query must be an object")
            raw = None
            if args.file:
                file = Path(args.file)
                if file.stat().st_size > 256 * 1024 * 1024: raise ValueError("File must be under 256 MB")
                raw = file.read_bytes()
            result = api(args.method, args.path, query=query, body=json.loads(args.json) if args.json else None,
                         raw=raw, timeout=120, binary=bool(args.output))
            if args.output:
                Path(args.output).write_bytes(result)
                print(f"Saved {len(result)} bytes to {args.output}")
                return 0
        elif args.action == "install":
            staged = json.loads(handle_tool("bar_app_stage", {"path": args.path}))
            info = staged.get("staged", {})
            print(f"Installing {info.get('name', '')} {info.get('version', '')}", file=sys.stderr)
            result = json.loads(handle_tool("bar_app_install", {"install_key": staged["install_key"]}))
        else:
            tool_name = {"list":"bar_apps_list", "run":"bar_app_launch", "remove":"bar_app_remove",
                         "settings":"bar_app_settings_get", "set-settings":"bar_app_settings_set",
                         "reset-settings":"bar_app_settings_reset", "stop":"bar_app_stop"}[args.action]
            tool_args = {"app_id": args.app_id} if hasattr(args, "app_id") else {}
            if args.action == "set-settings": tool_args["settings"] = json.loads(Path(args.file).read_text())
            result = json.loads(handle_tool(tool_name, tool_args))
        print(json.dumps(result, indent=2))
        return 0
    except (ValueError, OSError, KeyError) as exc:
        print(f"barkeep: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    if sys.argv[1:2] == ["--cli"]:
        sys.exit(cli(sys.argv[2:]))
    main()
