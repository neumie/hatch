#!/usr/bin/env bash
# down.sh - Tear down workspace infrastructure
# Sources: manifest, docker, process, ports

# Runtime installation root is dynamic; each file is checked directly in CI/tests.
# shellcheck disable=SC1091
source "$HATCH_LIB/manifest.sh"
# shellcheck disable=SC1091
source "$HATCH_LIB/ports.sh"
# shellcheck disable=SC1091
source "$HATCH_LIB/docker.sh"
# shellcheck disable=SC1091
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

# Determine the Docker Compose project name (must match what was used during setup)
# Construct from PROJECT_NAME + WORKSPACE_NAME (same as hatch_write_env in setup)
# Falls back to .env value or directory basename for legacy worktrees
COMPOSE_PROJECT=""
if [[ -n "${PROJECT_NAME:-}" && -n "${WORKSPACE_NAME:-}" ]]; then
  COMPOSE_PROJECT="${PROJECT_NAME}-${WORKSPACE_NAME}"
elif [[ -f .env ]]; then
  COMPOSE_PROJECT=$(grep '^COMPOSE_PROJECT_NAME=' .env 2>/dev/null | head -1 | cut -d= -f2)
fi
if [[ -z "$COMPOSE_PROJECT" ]]; then
  COMPOSE_PROJECT=$(basename "$(pwd)")
fi

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
  _output=$(docker volume ls --filter "name=${COMPOSE_PROJECT}" --format "  {{.Name}}" 2>/dev/null) || true
  echo "${_output:-  (none found)}"
  echo ""
fi

# Confirm unless --force
if [[ "$FORCE" != "true" ]] && [[ -t 0 ]]; then
  read -r -p "Continue? [y/N] " confirm
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
  _info "Stopping Docker services (compose project: $COMPOSE_PROJECT)"
  docker compose -p "${COMPOSE_PROJECT}" down -v --remove-orphans 2>&1 || true

  # Force remove any remaining containers
  CONTAINERS=$(docker ps -aq --filter "name=${PROJECT_NAME}-${WORKSPACE_NAME}-" 2>/dev/null)
  if [[ -n "$CONTAINERS" ]]; then
    _info "Removing containers"
    echo "$CONTAINERS" | xargs docker rm -f 2>/dev/null || true
  fi

  # Remove volumes matching the compose project name
  VOLUMES=$(docker volume ls -q --filter "name=${COMPOSE_PROJECT}" 2>/dev/null)
  if [[ -n "$VOLUMES" ]]; then
    _info "Removing volumes"
    echo "$VOLUMES" | xargs docker volume rm 2>/dev/null || true
  fi

  if ! hatch_docker_assert_workspace_removed "$COMPOSE_PROJECT"; then
    _die "Teardown incomplete; refusing to continue with stale Docker state"
  fi
  echo ""
fi

# Release port registry entry
_port_registry_release "$WORKSPACE_NAME" 2>/dev/null || true

# Final orphan sweep — catches Hatch-marked descendants that survived all
# previous cleanup, even when .hatch/pids is missing.
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
