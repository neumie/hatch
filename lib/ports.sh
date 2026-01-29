#!/usr/bin/env bash
# ports.sh - Port allocation and resolution
# Depends on: core.sh, manifest.sh

# Global port storage (bash 3.2 compatible - no associative arrays)
# Ports are stored in variables named: HATCH_PORT_<service_name>
# Also exported as PORT_<service_name> for convenience

# _sanitize_var_name NAME
# Converts a service name to a valid bash variable name
# Replaces hyphens and dots with underscores
_sanitize_var_name() {
  echo "$1" | tr '-.' '__'
}

# _parse_services VAR_NAME
# Parses a multiline string into individual entries (one per line)
# Trims leading/trailing whitespace from each line, skips empty lines and comments
# Returns one entry per line via stdout
_parse_services() {
  local var_name="$1"
  local services="${!var_name}"

  if [[ -n "$services" ]]; then
    # Process line by line: trim whitespace, skip empty lines and comments
    while IFS= read -r line; do
      # Trim leading and trailing whitespace
      line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      # Skip empty lines and comments
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      echo "$line"
    done <<< "$services"
  fi
}

# hatch_generate_ports WORKSPACE_NAME PROJECT_NAME
# Generates BASE_PORT using MD5 hash algorithm
# If workspace_name != project_name: hash-based port block (range 10000-60000, spacing 20)
# If workspace_name == project_name: use DEFAULT_BASE_PORT (from manifest, default 1481)
# Sets global variable: BASE_PORT
hatch_generate_ports() {
  local workspace_name="$1"
  local project_name="$2"

  if [[ "$workspace_name" == "$project_name" ]]; then
    # Main workspace - use default port
    BASE_PORT="${DEFAULT_BASE_PORT:-1481}"
    _info "Main workspace detected, using default base port: $BASE_PORT"
  else
    # Hash-based port allocation for isolated workspaces
    local hash
    hash=$(_md5 "$workspace_name")

    # Convert first 8 hex chars to decimal
    local hash_decimal
    hash_decimal=$((16#${hash:0:8}))

    # Map to port range 10000-60000 with spacing of 20
    local port_range=50000
    local min_port=10000
    local spacing=20

    BASE_PORT=$(( (hash_decimal % (port_range / spacing)) * spacing + min_port ))
    _info "Generated base port for workspace '$workspace_name': $BASE_PORT"
  fi

  export BASE_PORT
}

# hatch_allocate_ports
# Reads DOCKER_SERVICES, DOCKER_EXTRAS, DEV_SERVERS from manifest
# Assigns port offsets and sets port variables
# Docker services get sequential offsets starting from 0
# Docker extras continue after services
# Dev servers use their declared port_offset
# Sets variables: PORT_<name> and HATCH_PORT_<name> for each service
hatch_allocate_ports() {
  if [[ -z "${BASE_PORT:-}" ]]; then
    _die "BASE_PORT not set. Call hatch_generate_ports first."
  fi

  local offset=0
  local service_name
  local container_port
  local allocated_port

  # Process Docker services first
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue

    # Parse format: "name:port" or "name:port,port2,port3"
    service_name=$(echo "$service_spec" | cut -d: -f1)
    container_port=$(echo "$service_spec" | cut -d: -f2 | cut -d, -f1)

    allocated_port=$((BASE_PORT + offset))

    # Set both naming conventions (sanitize for valid bash var names)
    local safe_name
    safe_name=$(_sanitize_var_name "$service_name")
    eval "PORT_${safe_name}=${allocated_port}"
    eval "HATCH_PORT_${safe_name}=${allocated_port}"
    export "PORT_${safe_name}" "HATCH_PORT_${safe_name}"

    _info "Allocated port for docker service '$service_name': $allocated_port (container port: $container_port)"

    offset=$((offset + 1))
  done < <(_parse_services DOCKER_SERVICES)

  # Process Docker extras (continue offset sequence)
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue

    service_name=$(echo "$service_spec" | cut -d: -f1)
    container_port=$(echo "$service_spec" | cut -d: -f2 | cut -d, -f1)

    allocated_port=$((BASE_PORT + offset))

    local safe_name
    safe_name=$(_sanitize_var_name "$service_name")
    eval "PORT_${safe_name}=${allocated_port}"
    eval "HATCH_PORT_${safe_name}=${allocated_port}"
    export "PORT_${safe_name}" "HATCH_PORT_${safe_name}"

    _info "Allocated port for docker extra '$service_name': $allocated_port (container port: $container_port)"

    offset=$((offset + 1))
  done < <(_parse_services DOCKER_EXTRAS)

  # Process dev servers (use their declared port_offset)
  while IFS= read -r server_spec; do
    [[ -z "$server_spec" ]] && continue

    # Parse format: "name:directory:command:port_offset"
    local name directory command port_offset
    name=$(echo "$server_spec" | cut -d: -f1)
    port_offset=$(echo "$server_spec" | rev | cut -d: -f1 | rev)

    allocated_port=$((BASE_PORT + port_offset))

    local safe_name
    safe_name=$(_sanitize_var_name "$name")
    eval "PORT_${safe_name}=${allocated_port}"
    eval "HATCH_PORT_${safe_name}=${allocated_port}"
    export "PORT_${safe_name}" "HATCH_PORT_${safe_name}"

    _info "Allocated port for dev server '$name': $allocated_port"
  done < <(_parse_services DEV_SERVERS)
}

# hatch_resolve_port SERVICE_NAME
# Returns the allocated port for a named service
# Usage: PORT=$(hatch_resolve_port postgres)
hatch_resolve_port() {
  local service_name="$1"
  local safe_name
  safe_name=$(_sanitize_var_name "$service_name")
  local var_name="HATCH_PORT_${safe_name}"
  local port="${!var_name}"

  if [[ -z "$port" ]]; then
    _warn "No port allocated for service: $service_name"
    return 1
  fi

  echo "$port"
}

# hatch_check_ports
# Checks all allocated ports for availability
# Returns 0 if all available, 1 if any conflict
# Prints conflicts to stderr
hatch_check_ports() {
  local has_conflict=0
  local service_name
  local port

  # Collect all HATCH_PORT_* variables
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^HATCH_PORT_ ]]; then
      service_name=${var_name#HATCH_PORT_}
      port=$var_value

      if _check_port "$port"; then
        _error "Port conflict: $service_name (port $port) is already in use"
        has_conflict=1
      fi
    fi
  done < <(env | grep '^HATCH_PORT_')

  if [[ $has_conflict -eq 1 ]]; then
    _error "Port conflicts detected. Stop conflicting services or choose a different workspace name."
    return 1
  fi

  _success "All allocated ports are available"
  return 0
}
