#!/usr/bin/env bash
# manifest.sh - Project manifest loading and validation
# Depends on: core.sh

# hatch_detect_project
# Detects project name from: arg > git remote > directory name
# Usage: PROJECT=$(hatch_detect_project [project_name])
hatch_detect_project() {
  local project_name="${1:-}"

  # If project name provided as argument, use it
  if [[ -n "$project_name" ]]; then
    echo "$project_name"
    return 0
  fi

  # Try to extract from git remote
  if git remote get-url origin >/dev/null 2>&1; then
    local remote_url
    remote_url=$(git remote get-url origin)
    # Extract repo name from URL (handles both SSH and HTTPS)
    # git@github.com:user/repo.git -> repo
    # https://github.com/user/repo.git -> repo
    project_name=$(basename "$remote_url" .git)
    if [[ -n "$project_name" ]]; then
      echo "$project_name"
      return 0
    fi
  fi

  # Fall back to current directory name
  project_name=$(basename "$PWD")
  echo "$project_name"
}

# hatch_resolve_workspace
# Returns the workspace name (defaults to current directory basename)
# Usage: WORKSPACE=$(hatch_resolve_workspace)
hatch_resolve_workspace() {
  if [[ -n "${WORKSPACE_NAME:-}" ]]; then
    echo "$WORKSPACE_NAME"
  else
    basename "$PWD"
  fi
}

# hatch_load_manifest [project_name]
# Searches for and sources hatch.conf, then validates required fields
# Search order:
#   1. ./.hatch/hatch.conf (project .hatch directory)
#   2. ./hatch.conf (project root - legacy)
#   3. $HATCH_PROJECTS/{project_name}.conf (user local config)
# Dies with helpful message if not found or validation fails
hatch_load_manifest() {
  local project_name="${1:-}"
  local manifest_file=""

  # Detect project name if not provided
  if [[ -z "$project_name" ]]; then
    project_name=$(hatch_detect_project)
  fi

  # Search for manifest in order
  if [[ -f "./.hatch/hatch.conf" ]]; then
    manifest_file="./.hatch/hatch.conf"
  elif [[ -f "./hatch.conf" ]]; then
    manifest_file="./hatch.conf"
  elif [[ -f "$HATCH_PROJECTS/${project_name}.conf" ]]; then
    manifest_file="$HATCH_PROJECTS/${project_name}.conf"
  else
    _die "No hatch.conf found. Searched:\n  - ./.hatch/hatch.conf\n  - ./hatch.conf\n  - $HATCH_PROJECTS/${project_name}.conf\n\nRun 'hatch init' to create one."
  fi

  _info "Loading manifest: $manifest_file"

  # Source the manifest
  # shellcheck disable=SC1090
  source "$manifest_file"

  # Validate required fields
  if [[ -z "${PROJECT_NAME:-}" ]]; then
    _die "Invalid manifest: PROJECT_NAME is required"
  fi

  # Set defaults for optional fields
  PACKAGE_MANAGER="${PACKAGE_MANAGER:-none}"
  DOCKER_SERVICES="${DOCKER_SERVICES:-}"
  DOCKER_EXTRAS="${DOCKER_EXTRAS:-}"
  DEV_SERVERS="${DEV_SERVERS:-}"
  SETUP_STEPS="${SETUP_STEPS:-docker:up}"
  DEFAULT_BASE_PORT="${DEFAULT_BASE_PORT:-1481}"
  HOOKS_FILE="${HOOKS_FILE:-hatch.hooks.sh}"
  DOCKER_ENV="${DOCKER_ENV:-}"
  SECRETS="${SECRETS:-}"
  SECRET_FILES="${SECRET_FILES:-}"

  # Export key variables for use in subshells
  export PROJECT_NAME
  export PACKAGE_MANAGER
  export DOCKER_SERVICES
  export DOCKER_EXTRAS
  export DOCKER_ENV
  export DEV_SERVERS
  export SETUP_STEPS
  export DEFAULT_BASE_PORT
  export HOOKS_FILE
  export SECRETS
  export SECRET_FILES

  _success "Loaded manifest for project: $PROJECT_NAME"
}

# hatch_load_hooks
# Loads the hooks file if it exists
# Search order:
#   1. ./.hatch/$(basename $HOOKS_FILE) (project .hatch directory)
#   2. ./$(basename $HOOKS_FILE) (project root - legacy)
#   3. $HATCH_PROJECTS/{project_name}.hooks.sh (user local config)
# Does nothing if not found
hatch_load_hooks() {
  local project_name="${PROJECT_NAME:-}"
  local hooks_file=""
  local hooks_basename

  if [[ -z "$project_name" ]]; then
    project_name=$(hatch_detect_project)
  fi

  hooks_basename=$(basename "${HOOKS_FILE:-hatch.hooks.sh}")

  # Search for hooks file in order
  if [[ -f "./.hatch/$hooks_basename" ]]; then
    hooks_file="./.hatch/$hooks_basename"
  elif [[ -f "./$hooks_basename" ]]; then
    hooks_file="./$hooks_basename"
  elif [[ -f "$HATCH_PROJECTS/${project_name}.hooks.sh" ]]; then
    hooks_file="$HATCH_PROJECTS/${project_name}.hooks.sh"
  fi

  if [[ -n "$hooks_file" ]]; then
    _info "Loading hooks: $hooks_file"
    # shellcheck disable=SC1090
    source "$hooks_file"
    _success "Loaded hooks"
  fi
}
