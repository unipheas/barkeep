#!/bin/bash
# External Codex notifier. Codex passes one JSON payload as the final argument
# when a turn completes or needs approval.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload="${1:-{}}"

# Preserve the desktop Computer Use notifier when it is installed. BarKeep's
# setup can therefore replace Codex's single `notify` command without disabling
# the helper that keeps remote-control sessions in sync.
computer_use_notifier="$HOME/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
if [ -x "$computer_use_notifier" ]; then
    "$computer_use_notifier" turn-ended "$payload" >/dev/null 2>&1 &
fi

message=$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

event = data.get("type", "")
if event == "approval-requested":
    print("needs your approval")
else:
    print("is waiting for your response")
' 2>/dev/null)
[ -n "$message" ] || message="is waiting for your response"

printf '{"message":"%s"}' "$message" |
    BARKEEP_AGENT=Codex "$SCRIPT_DIR/agent-notification.sh"
