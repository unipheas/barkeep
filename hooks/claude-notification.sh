#!/bin/bash
# Claude Code Notification hook: Claude is waiting on permission or input —
# flash the Busy Bar red with the actual message. Never blocks Claude.
BUSYBAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/barkeep"

input=$(cat)
msg=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("message","Claude needs your input"))' 2>/dev/null)
[ -n "$msg" ] || msg="Claude needs your input"

(
    "$BUSYBAR" send "Claude: ${msg:0:120}" -c red -l red -t 45 >/dev/null 2>&1
) &
exit 0
