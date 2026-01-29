#!/usr/bin/env bash
# down.sh - Tear down workspace infrastructure
# Sources: manifest, docker, process, ports

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/docker.sh"
source "$HATCH_LIB/process.sh"

# Parse arguments
FORCE=false
for arg in "$@"; do
  if [[ "$arg" == "--force" ]]; then
    FORCE=true
  fi
done

# Load manifest if exists
PROJECT_NAME=$(hatch_detect_project)
WORKSPACE_NAME=$(hatch_resolve_workspace)

# Try to load manifest, but don't fail if it doesn't exist
hatch_load_manifest "$PROJECT_NAME" 2>/dev/null || true

_header "Tear Down Workspace"
_info "Workspace: $WORKSPACE_NAME"
_info "Directory: $(pwd)"
echo ""

# Show what will be removed
if command -v docker >/dev/null 2>&1; then
  echo "Containers to remove:"
  docker ps -a --filter "name=${WORKSPACE_NAME}-" --format "  {{.Names}} ({{.Status}})" 2>/dev/null || echo "  (none found)"
  echo ""
  echo "Volumes to remove:"
  docker volume ls --filter "name=${WORKSPACE_NAME}" --format "  {{.Name}}" 2>/dev/null || echo "  (none found)"
  echo ""
fi

# Confirm unless --force
if [[ "$FORCE" != "true" ]] && [[ -t 0 ]]; then
  read -p "Continue? [y/N] " confirm
  if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
    echo "Cancelled"
    exit 0
  fi
else
  _info "Auto-confirming (non-interactive or --force)"
fi

echo ""

# Stop dev servers if running
if [[ -f .hatch/pids ]]; then
  hatch_stop_servers
  echo ""
fi

# Stop Docker services and remove containers + volumes
if command -v docker >/dev/null 2>&1; then
  _info "Stopping Docker services"
  docker compose -p "$WORKSPACE_NAME" down -v --remove-orphans 2>&1 || true

  # Force remove any remaining containers
  CONTAINERS=$(docker ps -aq --filter "name=${WORKSPACE_NAME}-" 2>/dev/null)
  if [[ -n "$CONTAINERS" ]]; then
    _info "Removing containers"
    echo "$CONTAINERS" | xargs docker rm -f 2>/dev/null || true
  fi

  # Remove volumes
  VOLUMES=$(docker volume ls -q --filter "name=${WORKSPACE_NAME}" 2>/dev/null)
  if [[ -n "$VOLUMES" ]]; then
    _info "Removing volumes"
    echo "$VOLUMES" | xargs docker volume rm 2>/dev/null || true
  fi
  echo ""
fi

# Release port registry entry
_port_registry_release "$WORKSPACE_NAME" 2>/dev/null || true

# Clean up runtime state only
_info "Cleaning up runtime state"
rm -f .hatch/pids 2>/dev/null && echo "  Removed .hatch/pids"
rm -f .hatch/*.log 2>/dev/null && echo "  Removed .hatch/*.log"

echo ""
_success "Tear down complete"
