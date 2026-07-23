#!/bin/bash
# Notify the Busy Bar when Codex or Claude needs permission or user input.
# Never blocks the agent.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUSYBAR="${BARKEEP_CLI:-}"
if [ -z "$BUSYBAR" ] && [ -x "$SCRIPT_DIR/../bin/barkeep" ]; then
    BUSYBAR="$SCRIPT_DIR/../bin/barkeep"
elif [ -z "$BUSYBAR" ]; then
    BUSYBAR="$(command -v barkeep 2>/dev/null)"
fi
[ -n "$BUSYBAR" ] || exit 0

agent="${BARKEEP_AGENT:-Agent}"
input=$(cat)
msg=$(printf '%s' "$input" | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data.get("message") or data.get("reason") or data.get("tool_name") or "needs your input")
' 2>/dev/null)
[ -n "$msg" ] || msg="needs your input"

(
    "$BUSYBAR" send "$agent: ${msg:0:120}" -c red -l red -t 45 >/dev/null 2>&1
) &
exit 0
