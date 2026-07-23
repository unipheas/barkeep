#!/bin/bash
# Record when an agent turn starts so the Stop hook can notify only for
# long-running tasks. Compatible with Codex and Claude Code hook payloads.
input=$(cat)
sid=$(printf '%s' "$input" | /usr/bin/python3 -c 'import sys,json;print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null)
agent="${BARKEEP_AGENT:-Agent}"
agent_key=$(printf '%s' "$agent" | tr '[:upper:] ' '[:lower:]-')
mkdir -p /tmp/barkeep-agent
date +%s > "/tmp/barkeep-agent/${agent_key}-${sid:-default}"
exit 0
