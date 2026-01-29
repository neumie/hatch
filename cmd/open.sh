#!/usr/bin/env bash
# open.sh - Open service URLs in browser
# Sources: manifest, ports

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

SERVICE="${1:-}"

if [[ -z "$SERVICE" ]]; then
  # No service specified, list available
  echo "Available services:"
  echo ""
  
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    name=$(echo "$service_spec" | cut -d: -f1)
    port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
    if [[ -n "$port" ]]; then
      echo "  $name: http://localhost:$port"
    fi
  done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS; _parse_services DEV_SERVERS)
  
  echo ""
  echo "Usage: hatch open <service-name>"
  exit 0
fi

# Open the specified service
PORT=$(hatch_resolve_port "$SERVICE")
if [[ -z "$PORT" ]]; then
  _error "Service not found: $SERVICE"
  exit 1
fi

URL="http://localhost:$PORT"
_info "Opening: $URL"
_open_url "$URL"
