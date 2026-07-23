#!/bin/bash
# Claude Code Stop hook: if the turn ran longer than THRESHOLD seconds,
# scroll a done-message on the Busy Bar and chime. Never blocks Claude.
BUSYBAR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/barkeep"
THRESHOLD=60

input=$(cat)
sid=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
stamp="/tmp/busybar-claude/${sid:-default}"
[ -f "$stamp" ] || exit 0
start=$(cat "$stamp" 2>/dev/null)
rm -f "$stamp"
[ -n "$start" ] || exit 0

elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -ge "$THRESHOLD" ] || exit 0

mins=$(( (elapsed + 30) / 60 ))
(
    "$BUSYBAR" send "Claude finished (${mins}m task)" -c green -l green -t 30 >/dev/null 2>&1
    "$BUSYBAR" sound >/dev/null 2>&1
) &
exit 0
