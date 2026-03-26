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

# Check if Docker daemon is responsive (3s timeout, avoids hanging)
DOCKER_AVAILABLE=false
if _docker_responsive 3; then
  DOCKER_AVAILABLE=true
fi

# Show what will be removed
if [[ "$DOCKER_AVAILABLE" == "true" ]]; then
  echo "Containers to remove:"
  _output=$(docker ps -a --filter "name=${PROJECT_NAME}-${WORKSPACE_NAME}-" --format "  {{.Names}} ({{.Status}})" 2>/dev/null) || true
  echo "${_output:-  (none found)}"
  echo ""
  echo "Volumes to remove:"
  _output=$(docker volume ls --filter "name=${PROJECT_NAME}-${WORKSPACE_NAME}" --format "  {{.Name}}" 2>/dev/null) || true
  echo "${_output:-  (none found)}"
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
if [[ "$DOCKER_AVAILABLE" == "true" ]]; then
  _info "Stopping Docker services"
  docker compose -p "${PROJECT_NAME}-${WORKSPACE_NAME}" down -v --remove-orphans 2>&1 || true

  # Force remove any remaining containers
  CONTAINERS=$(docker ps -aq --filter "name=${PROJECT_NAME}-${WORKSPACE_NAME}-" 2>/dev/null)
  if [[ -n "$CONTAINERS" ]]; then
    _info "Removing containers"
    echo "$CONTAINERS" | xargs docker rm -f 2>/dev/null || true
  fi

  # Remove volumes
  VOLUMES=$(docker volume ls -q --filter "name=${PROJECT_NAME}-${WORKSPACE_NAME}" 2>/dev/null)
  if [[ -n "$VOLUMES" ]]; then
    _info "Removing volumes"
    echo "$VOLUMES" | xargs docker volume rm 2>/dev/null || true
  fi
  echo ""
fi

# Release port registry entry
_port_registry_release "$WORKSPACE_NAME" 2>/dev/null || true

# Final orphan sweep — catches processes that survived all previous cleanup
# (works without .hatch/pids by scanning the workspace directory in process args)
hatch_sweep_orphans

# Clean up runtime state only
_info "Cleaning up runtime state"
rm -f .hatch/pids 2>/dev/null && echo "  Removed .hatch/pids"
rm -f .hatch/*.log 2>/dev/null && echo "  Removed .hatch/*.log"

# Call post_down hook if exists
hatch_load_hooks 2>/dev/null || true
if type post_down &>/dev/null; then
  echo ""
  _info "Running post_down hook"
  post_down
fi

echo ""
_success "Tear down complete"
