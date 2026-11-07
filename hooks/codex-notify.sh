#!/bin/bash
# Preserve the Codex desktop notifier and send a nonblocking BarKeep signal.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BARKEEP_AGENT=Codex
payload="${1:-}"
[[ -n "$payload" ]] || payload='{}'
exec /usr/bin/python3 "$SCRIPT_DIR/agent_hook.py" codex "$payload"
