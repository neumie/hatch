#!/usr/bin/env bash
# export.sh - Export project data
# Sources: manifest, ports, data

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/data.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project "$@")
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

# Export data
hatch_export_data
