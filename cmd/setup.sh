#!/usr/bin/env bash
# setup.sh - Full project setup
# Sources: manifest, ports, docker, secrets, migrate, data, process

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/docker.sh"
source "$HATCH_LIB/secrets.sh"
source "$HATCH_LIB/migrate.sh"
source "$HATCH_LIB/data.sh"
source "$HATCH_LIB/process.sh"
source "$HATCH_LIB/mcp.sh"

_header "Hatch Setup"

# Detect project and workspace
PROJECT_NAME=$(hatch_detect_project "$@")
WORKSPACE_NAME=$(hatch_resolve_workspace)

_info "Project: $PROJECT_NAME"
_info "Workspace: $WORKSPACE_NAME"
echo ""

# Load manifest
hatch_load_manifest "$PROJECT_NAME"

# Install dependencies if package manager configured
if [[ "${PACKAGE_MANAGER:-none}" != "none" ]]; then
  _header "Installing dependencies"
  _pkg_install
  echo ""
fi

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports
echo ""

# Check port availability (always check, tolerate own containers)
DOCKER_RUNNING=false
if hatch_docker_running; then
  _info "Docker services already running for this workspace"
  DOCKER_RUNNING=true
fi

_info "Checking port availability..."
if ! hatch_check_ports_smart "$WORKSPACE_NAME"; then
  echo ""
  _warn "Port conflicts detected. Choose an option:"
  echo "  1) Kill conflicting processes and continue"
  # Identify conflicting workspaces to show a useful option 2
  _conflicting_ws=""
  if _conflicting_ws=$(_find_conflicting_workspaces "$WORKSPACE_NAME" 2>/dev/null); then
    echo "  2) Show conflicting workspace info and abort"
  else
    echo "  2) Abort"
  fi
  echo ""
  if [[ -t 0 ]]; then
    read -p "Option [1/2]: " _port_choice
  else
    _error "Non-interactive shell, cannot prompt. Aborting."
    exit 1
  fi
  case "${_port_choice}" in
    1)
      _info "Killing conflicting processes..."
      _kill_conflicting_ports "$WORKSPACE_NAME"
      # Re-check after killing
      if ! hatch_check_ports_smart "$WORKSPACE_NAME"; then
        _error "Some port conflicts remain after killing processes. Aborting."
        exit 1
      fi
      ;;
    2)
      if [[ -n "$_conflicting_ws" ]]; then
        echo ""
        _info "Conflicting workspace(s):"
        echo "$_conflicting_ws" | while read -r ws; do
          echo "  - $ws"
        done
        echo ""
        _info "To archive a conflicting workspace, cd into its directory and run:"
        echo "  hatch archive"
      fi
      _error "Aborted."
      exit 1
      ;;
    *)
      _error "Aborted."
      exit 1
      ;;
  esac
fi

# Write configuration files
hatch_write_env "$WORKSPACE_NAME"
hatch_write_docker_override "$WORKSPACE_NAME"
echo ""

# Write secrets from manifest, link external secrets, inject ports
hatch_write_secrets
hatch_link_secrets
hatch_inject_ports

# Generate MCP configuration
hatch_generate_mcp_config
echo ""

# Execute SETUP_STEPS in order
_header "Executing setup steps"

for step in ${SETUP_STEPS:-docker:up}; do
  case "$step" in
    docker:up)
      if [[ "$DOCKER_RUNNING" == "true" ]]; then
        _info "Docker already running, skipping docker:up"
      else
        hatch_docker_up
      fi
      ;;
    docker:down)
      hatch_docker_down
      ;;
    deps:install)
      _info "Installing dependencies"
      _pkg_install
      ;;
    migrate:execute)
      if [[ "$DOCKER_RUNNING" != "true" ]]; then
        # Allow Docker services time to be ready
        sleep 2
      fi
      hatch_migrate execute
      ;;
    data:import)
      if [[ "$DOCKER_RUNNING" != "true" ]]; then
        hatch_import_data
      else
        _info "Docker was already running, skipping data import"
      fi
      ;;
    custom:*)
      func_name="${step#custom:}"
      if type "$func_name" &>/dev/null; then
        _info "Running custom function: $func_name"
        "$func_name"
      else
        _warn "Custom function not found: $func_name"
      fi
      ;;
    *)
      _warn "Unknown setup step: $step"
      ;;
  esac
done

echo ""

# Load and call post_setup hook if exists
hatch_load_hooks
if type post_setup &>/dev/null; then
  _info "Running post_setup hook"
  post_setup
  echo ""
fi

# Print summary
_header "Setup Complete"
echo ""
echo "URLs:"

# Show Docker services
while IFS= read -r service_spec; do
  [[ -z "$service_spec" ]] && continue
  name=$(echo "$service_spec" | cut -d: -f1)
  port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
  if [[ -n "$port" ]]; then
    echo "  $name: http://localhost:$port"
  fi
done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS)

echo ""
echo "To start dev servers, run:"
echo "  hatch run"
