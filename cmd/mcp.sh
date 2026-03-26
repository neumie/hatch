#!/usr/bin/env bash
# mcp.sh - Regenerate MCP server configuration
# Sources: manifest, ports, mcp

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/mcp.sh"

# Detect project and workspace
PROJECT_NAME=$(hatch_detect_project "$@")
WORKSPACE_NAME=$(hatch_resolve_workspace)

# Load manifest
hatch_load_manifest "$PROJECT_NAME"

# Load ports (needed for {PORT_x} resolution in MCP_ENV)
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

# Generate MCP configurations
hatch_generate_mcp_config
hatch_generate_remote_mcp_config
