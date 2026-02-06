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
#   3. $HATCH_PROJECTS/{project_name}.hooks.{ext} (user local config)
# Supports .sh (sourced into shell) and .ts (executed via tsx subprocess)
# Does nothing if not found
hatch_load_hooks() {
  local project_name="${PROJECT_NAME:-}"
  local hooks_file=""
  local hooks_basename

  if [[ -z "$project_name" ]]; then
    project_name=$(hatch_detect_project)
  fi

  hooks_basename=$(basename "${HOOKS_FILE:-hatch.hooks.sh}")
  local hooks_ext="${hooks_basename##*.}"

  # Search for hooks file in order
  if [[ -f "./.hatch/$hooks_basename" ]]; then
    hooks_file="./.hatch/$hooks_basename"
  elif [[ -f "./$hooks_basename" ]]; then
    hooks_file="./$hooks_basename"
  elif [[ -f "$HATCH_PROJECTS/${project_name}.hooks.${hooks_ext}" ]]; then
    hooks_file="$HATCH_PROJECTS/${project_name}.hooks.${hooks_ext}"
  fi

  if [[ -n "$hooks_file" ]]; then
    _info "Loading hooks: $hooks_file"
    case "$hooks_ext" in
      sh)
        # shellcheck disable=SC1090
        source "$hooks_file"
        ;;
      ts)
        _load_ts_hooks "$hooks_file"
        ;;
      *)
        _warn "Unrecognized hooks extension '.$hooks_ext' — sourcing as shell script"
        # shellcheck disable=SC1090
        source "$hooks_file"
        ;;
    esac
    _success "Loaded hooks"
  fi
}

# _load_ts_hooks HOOKS_FILE
# Generates bash wrapper functions that delegate to the TypeScript hooks runner.
# Each wrapper calls: npx tsx <runner> <hooks_file> <func_name> [args...]
# All HATCH_* env vars (ports, project, etc.) are available via process.env.
_load_ts_hooks() {
  local hooks_file="$1"
  local abs_hooks_file
  abs_hooks_file="$(cd "$(dirname "$hooks_file")" && pwd)/$(basename "$hooks_file")"

  local runner_path="$HATCH_HOME/lib/ts-hook-runner.ts"

  # Determine TS execution command based on package manager
  # Uses an array to safely handle commands with multiple words (e.g. "npx tsx")
  local ts_cmd
  ts_cmd=()
  if [[ "${PACKAGE_MANAGER:-npm}" == "bun" ]]; then
    if ! command -v bun &>/dev/null; then
      _die "TypeScript hooks require bun but it's not installed"
    fi
    ts_cmd=(bun)
  else
    if ! command -v npx &>/dev/null; then
      _die "TypeScript hooks require npx (Node.js) but it's not installed"
    fi
    ts_cmd=(npx tsx)
  fi

  # Collect hook function names referenced in config.
  # Note: lifecycle hooks like post_setup are discovered via the TS export scan below,
  # not this config-based collection.
  local hook_names=""

  # From SETUP_STEPS custom:* entries
  for step in ${SETUP_STEPS:-}; do
    case "$step" in
      custom:*) hook_names="$hook_names ${step#custom:}" ;;
    esac
  done

  # From DATA_IMPORT_CMD and DATA_EXPORT_CMD
  [[ -n "${DATA_IMPORT_CMD:-}" ]] && hook_names="$hook_names $DATA_IMPORT_CMD"
  [[ -n "${DATA_EXPORT_CMD:-}" ]] && hook_names="$hook_names $DATA_EXPORT_CMD"

  # Scan TS file for exported functions and arrow function exports
  # Matches: export function foo, export async function foo,
  #          export const foo =, export let foo =, export var foo =
  # Note: won't match default exports, re-exports, or multiline export patterns.
  # This is intentional — hooks should use simple named exports.
  local ts_exports
  ts_exports=$(grep -oE 'export\s+(async\s+)?function\s+[a-zA-Z_][a-zA-Z0-9_]*|export\s+(const|let|var)\s+[a-zA-Z_][a-zA-Z0-9_]*\s*=' "$hooks_file" \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*(\s*=)?$' | sed 's/[[:space:]]*=//') || true
  hook_names="$hook_names $ts_exports"

  # Deduplicate
  hook_names=$(echo "$hook_names" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')

  # Store ts_cmd array, runner path, and hooks path in globals for the wrapper to reference.
  # These are set once per _load_ts_hooks call; subsequent calls overwrite them,
  # which is fine since all hooks in one file share the same runner config.
  _HATCH_TS_CMD=("${ts_cmd[@]}")
  _HATCH_TS_RUNNER="$runner_path"
  _HATCH_TS_HOOKS_FILE="$abs_hooks_file"

  # Generate a bash wrapper for each hook function
  for name in $hook_names; do
    # Validate name is a legal bash identifier
    if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      _warn "Skipping invalid hook name: $name"
      continue
    fi
    # Each wrapper delegates to the TS runner via the stored command array.
    # Using eval only for the function name; paths are quoted in the global vars.
    # shellcheck disable=SC2086
    eval "${name}() { \"\${_HATCH_TS_CMD[@]}\" \"\$_HATCH_TS_RUNNER\" \"\$_HATCH_TS_HOOKS_FILE\" \"${name}\" \"\$@\"; }"
  done
}
