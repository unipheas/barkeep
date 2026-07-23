#!/bin/bash
# Claude Code UserPromptSubmit hook: record when this turn started so the
# Stop hook can alert the Busy Bar only for long-running tasks.
input=$(cat)
sid=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
mkdir -p /tmp/busybar-claude
date +%s > "/tmp/busybar-claude/${sid:-default}"
exit 0
