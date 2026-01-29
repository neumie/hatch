#!/usr/bin/env bash
# status.sh - Show Docker and dev server status
# Sources: manifest, ports, docker, process

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/docker.sh"
source "$HATCH_LIB/process.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

_header "$PROJECT_NAME Status"
echo ""

# Docker services
_info "Docker Services:"
hatch_docker_status
echo ""

# Dev servers
_info "Dev Servers:"
hatch_server_status
echo ""

# URLs
_info "Available URLs:"

# Show all services with ports
while IFS= read -r service_spec; do
  [[ -z "$service_spec" ]] && continue
  name=$(echo "$service_spec" | cut -d: -f1)
  port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
  if [[ -n "$port" ]]; then
    echo "  $name: http://localhost:$port"
  fi
done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS; _parse_services DEV_SERVERS)
