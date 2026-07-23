#!/bin/bash
# Compatibility wrapper for existing Claude Code configurations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BARKEEP_AGENT="${BARKEEP_AGENT:-Claude}"
exec "$SCRIPT_DIR/agent-stop.sh"
