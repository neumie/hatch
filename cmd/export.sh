#!/usr/bin/env bash
# export.sh - Export project data (local or remote)
# Sources: manifest, ports, data

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/data.sh"

# Parse flags
_remote_mode=""
_remote_env=""
_positional=()
_next_is_env=""

for arg in "$@"; do
  if [[ -n "$_next_is_env" ]]; then
    _next_is_env=""
    # If the arg after --remote looks like a flag, it's not an env name
    if [[ "$arg" != --* ]]; then
      _remote_env="$arg"
      continue
    fi
  fi
  case "$arg" in
    --remote)
      _remote_mode=1
      _next_is_env=1
      ;;
    *)
      _positional+=("$arg")
      ;;
  esac
done

# Load manifest
PROJECT_NAME=$(hatch_detect_project "${_positional[@]+"${_positional[@]}"}")
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

if [[ -n "$_remote_mode" ]]; then
  # --- Remote export mode ---

  if [[ -z "${DATA_REMOTE_ENVS:-}" ]]; then
    _die "DATA_REMOTE_ENVS not configured in hatch.conf. Add remote environments to use --remote export."
  fi

  # Parse environments into parallel arrays
  _env_names=()
  _env_urls=()
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local_name="${entry%% *}"
    local_url="${entry#* }"
    _env_names+=("$local_name")
    _env_urls+=("$local_url")
  done < <(_parse_services DATA_REMOTE_ENVS)

  if [[ ${#_env_names[@]} -eq 0 ]]; then
    _die "No environments defined in DATA_REMOTE_ENVS."
  fi

  # Resolve environment
  if [[ -n "$_remote_env" ]]; then
    # Direct selection via argument
    _selected_idx=""
    for i in "${!_env_names[@]}"; do
      if [[ "${_env_names[$i]}" == "$_remote_env" ]]; then
        _selected_idx=$i
        break
      fi
    done
    if [[ -z "$_selected_idx" ]]; then
      _error "Unknown environment: $_remote_env"
      _info "Available environments:"
      for i in "${!_env_names[@]}"; do
        _info "  ${_env_names[$i]}  ${_env_urls[$i]}"
      done
      exit 1
    fi
  else
    # Interactive selection
    echo ""
    echo "Select environment:"
    for i in "${!_env_names[@]}"; do
      echo "  $((i + 1))) ${_env_names[$i]}  ${_env_urls[$i]}"
    done
    echo ""
    read -rp "> " _choice

    if ! [[ "$_choice" =~ ^[0-9]+$ ]] || [[ "$_choice" -lt 1 ]] || [[ "$_choice" -gt ${#_env_names[@]} ]]; then
      _die "Invalid selection."
    fi
    _selected_idx=$((_choice - 1))
  fi

  HATCH_REMOTE_URL="${_env_urls[$_selected_idx]}"
  _info "Environment: ${_env_names[$_selected_idx]} ($HATCH_REMOTE_URL)"

  # Prompt for token
  echo ""
  read -rsp "Enter token: " HATCH_REMOTE_TOKEN
  echo ""

  if [[ -z "$HATCH_REMOTE_TOKEN" ]]; then
    _die "Token cannot be empty."
  fi

  # Load hooks (needs manifest loaded first for hook discovery)
  hatch_load_hooks

  # Export from remote
  hatch_export_remote_data
else
  # --- Local export mode (existing behavior) ---

  # Generate and allocate ports
  hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
  hatch_allocate_ports

  # Load hooks (provides project_export and other custom functions)
  hatch_load_hooks

  # Export data
  hatch_export_data
fi
