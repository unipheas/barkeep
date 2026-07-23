#!/bin/bash
# Notify the Busy Bar when a long-running Codex or Claude turn finishes.
# Never blocks the agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUSYBAR="${BARKEEP_CLI:-}"
if [ -z "$BUSYBAR" ] && [ -x "$SCRIPT_DIR/../bin/barkeep" ]; then
    BUSYBAR="$SCRIPT_DIR/../bin/barkeep"
elif [ -z "$BUSYBAR" ]; then
    BUSYBAR="$(command -v barkeep 2>/dev/null)"
fi
[ -n "$BUSYBAR" ] || exit 0

THRESHOLD="${BARKEEP_AGENT_THRESHOLD:-60}"
agent="${BARKEEP_AGENT:-Agent}"
agent_key=$(printf '%s' "$agent" | tr '[:upper:] ' '[:lower:]-')

input=$(cat)
sid=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
stamp="/tmp/barkeep-agent/${agent_key}-${sid:-default}"
[ -f "$stamp" ] || exit 0
start=$(cat "$stamp" 2>/dev/null)
rm -f "$stamp"
[ -n "$start" ] || exit 0

elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -ge "$THRESHOLD" ] || exit 0
mins=$(( (elapsed + 30) / 60 ))

(
    "$BUSYBAR" send "$agent finished (${mins}m task)" -c green -l green -t 30 >/dev/null 2>&1
    "$BUSYBAR" sound >/dev/null 2>&1
) &
exit 0
