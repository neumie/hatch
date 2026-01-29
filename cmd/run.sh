#!/usr/bin/env bash
# run.sh - Start dev servers in background
# Sources: manifest, ports, process

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/process.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

# Start servers (daemonized - they persist after this script exits)
hatch_start_servers "$@"

if [[ -s .hatch/pids ]]; then
  _info "Servers running in background. Use 'hatch stop' to shut down."
fi
