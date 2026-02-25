#!/usr/bin/env bash
# reset.sh - Reset workspace (tear down + full setup)

source "$HATCH_LIB/core.sh"

_header "Hatch Reset"
_info "Tearing down and re-setting up workspace..."
echo ""

# Tear down (auto-confirm)
"$HATCH_HOME/bin/hatch" down --force

echo ""

# Full setup
"$HATCH_HOME/bin/hatch" setup "$@"
