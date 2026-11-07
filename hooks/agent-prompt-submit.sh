#!/bin/bash
# Compatibility entry point; the shared helper never blocks the agent on device I/O.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 "$SCRIPT_DIR/agent_hook.py" prompt
