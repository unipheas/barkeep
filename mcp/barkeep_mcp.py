#!/usr/bin/env python3
"""Zero-dependency MCP stdio server exposing the Busy Bar's local HTTP API.

Tools: bar_send_message, bar_set_busy, bar_start_timer, bar_clear, bar_status.
Host defaults to the USB address (10.0.4.20); override with BARKEEP_HOST.
"""
import json
import os
import sys
import time
import urllib.request
import urllib.parse

HOST = os.environ.get("BARKEEP_HOST", "10.0.4.20")
TOKEN = os.environ.get("BARKEEP_TOKEN", "")
API = f"http://{HOST}/api"

COLORS = {
    "white": "#FFFFFFFF", "red": "#FF3B30FF", "green": "#34C759FF",
    "blue": "#0A84FFFF", "yellow": "#FFD60AFF", "orange": "#FF9500FF",
    "purple": "#BF5AF2FF", "cyan": "#32ADE6FF", "pink": "#FF2D55FF",
}

TOOLS = [
    {
        "name": "bar_send_message",
        "description": "Scroll a text message across the Busy Bar's front LED display. "
                       "ASCII only (the device uses bitmap fonts). Fails while a busy "
                       "session is active — the device rejects drawing during sessions.",
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


def api(method, path, body=None, query=None):
    url = API + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    if TOKEN:
        req.add_header("Authorization", f"bearer {TOKEN}")
    with urllib.request.urlopen(req, timeout=8) as resp:
        return json.loads(resp.read().decode() or "{}")


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
    if name == "bar_send_message":
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
        put_snapshot({
            "type": "SIMPLE",
            "card_id": "00000000-0000-0000-0000-000000000000",
            "time_left_ms": args["minutes"] * 60000,
            "is_paused": False,
            "busy_bar_settings": bar_settings(args.get("theme", "on_air")),
        })
        return f"Timer started: {args['minutes']} minutes"

    if name == "bar_clear":
        for app in ("busybar_mcp", "busybar_cli", "busybar_mac"):
            try:
                api("DELETE", "/display/draw", query={"application_name": app})
            except Exception:
                pass
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
            continue
        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            reply(msg_id, {
                "protocolVersion": msg.get("params", {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "barkeep", "version": "1.1.0"},
                "instructions": "Use these tools when the user asks to control or inspect their Busy Bar. "
                                "Do not change busy state, start timers, clear the display, or send "
                                "messages unless the user requests that action.",
            })
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            reply(msg_id, {"tools": TOOLS})
        elif method == "tools/call":
            params = msg.get("params", {})
            try:
                text = handle_tool(params.get("name"), params.get("arguments") or {})
                reply(msg_id, {"content": [{"type": "text", "text": text}]})
            except Exception as exc:
                reply(msg_id, {"content": [{"type": "text", "text": f"Error: {exc}"}],
                               "isError": True})
        elif method == "ping":
            reply(msg_id, {})
        elif msg_id is not None:
            reply(msg_id, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()
