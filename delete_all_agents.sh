#!/usr/bin/env bash
# ==============================================================================
# Backward Compatibility Wrapper
# Note: delete_all_agents.sh has been consolidated into housekeeping.sh.
# Running this wrapper forwards directly to:
#   ./housekeeping.sh --all-agents "$@"
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/housekeeping.sh" --all-agents "$@"
