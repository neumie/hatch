#!/usr/bin/env bash
# ports.sh - Port allocation, resolution, and cross-workspace coordination
# Depends on: core.sh, manifest.sh

# Global port storage (bash 3.2 compatible - no associative arrays)
# Ports are stored in variables named: HATCH_PORT_<service_name>
# Also exported as PORT_<service_name> for convenience
# Multi-port services also set: HATCH_PORTMAP_<service>_<container_port>=<host_port>

# Port spacing: number of host ports reserved per workspace
HATCH_PORT_SPACING=20

# Port Registry
# File: $HATCH_HOME/port-registry (one line per active workspace)
# Format: BASE_PORT\tWORKSPACE_NAME\tPROJECT_DIR\tTIMESTAMP\tPID
HATCH_PORT_REGISTRY="${HATCH_HOME}/port-registry"

# _sanitize_var_name NAME
# Converts a service name to a valid bash variable name
# Replaces hyphens and dots with underscores
_sanitize_var_name() {
  echo "$1" | tr -- '-.' '__'
}

# _parse_services VAR_NAME
# Parses a multiline string into individual entries (one per line)
# Trims leading/trailing whitespace from each line, skips empty lines and comments
# Returns one entry per line via stdout
_parse_services() {
  local var_name="$1"
  local services="${!var_name:-}"

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

# ---------------------------------------------------------------------------
# Port Registry - Cross-workspace coordination via ~/.hatch/port-registry
# ---------------------------------------------------------------------------

# _port_registry_lock
# Acquires a file lock using mkdir (atomic on all POSIX filesystems, bash 3.2 compatible)
_port_registry_lock() {
  local lockdir="${HATCH_PORT_REGISTRY}.lock"
  local max_wait=5
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))
    if [[ $waited -ge $max_wait ]]; then
      # Check for stale lock (older than 30 seconds)
      if [[ -d "$lockdir" ]]; then
        local lock_age
        if [[ "$HATCH_PLATFORM" == "darwin" ]]; then
          lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir") ))
        else
          lock_age=$(( $(date +%s) - $(stat -c %Y "$lockdir") ))
        fi
        if [[ $lock_age -gt 30 ]]; then
          _warn "Breaking stale port registry lock (age: ${lock_age}s)"
          rmdir "$lockdir" 2>/dev/null || true
          continue
        fi
      fi
      _warn "Cannot acquire port registry lock after ${max_wait}s (non-fatal)"
      return 1
    fi
    sleep 1
  done
  return 0
}

# _port_registry_unlock
_port_registry_unlock() {
  rmdir "${HATCH_PORT_REGISTRY}.lock" 2>/dev/null || true
}

# _registry_entry_alive DIR PID
# Returns 0 if the workspace appears still active
_registry_entry_alive() {
  local dir="$1"
  local pid="$2"

  # Check if the setup PID is still running
  if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  # Check if Docker containers for this workspace are running
  if [[ -d "$dir" ]] && command -v docker >/dev/null 2>&1; then
    local ws_name
    ws_name=$(basename "$dir")
    local running_names
    running_names=$(docker ps --format '{{.Names}}' 2>/dev/null)
    if echo "$running_names" | grep -Fq "${ws_name}-"; then
      return 0
    fi
  fi

  return 1  # Appears dead
}

# _port_registry_conflict BASE_PORT WORKSPACE_NAME
# Returns 0 if BASE_PORT is claimed by a DIFFERENT active workspace
_port_registry_conflict() {
  local base_port="$1"
  local workspace_name="$2"

  if [[ ! -f "$HATCH_PORT_REGISTRY" ]]; then
    return 1  # No registry, no conflict
  fi

  while IFS=$'\t' read -r reg_port reg_workspace reg_dir reg_ts reg_pid; do
    [[ -z "$reg_port" ]] && continue
    if [[ "$reg_port" == "$base_port" ]] && [[ "$reg_workspace" != "$workspace_name" ]]; then
      if _registry_entry_alive "$reg_dir" "$reg_pid"; then
        return 0  # Conflict: port claimed by live workspace
      fi
    fi
  done < "$HATCH_PORT_REGISTRY"

  return 1  # No conflict
}

# _port_registry_claim BASE_PORT WORKSPACE_NAME PROJECT_DIR
# Registers this workspace's port claim. Removes any prior entry for this workspace.
_port_registry_claim() {
  local base_port="$1"
  local workspace_name="$2"
  local project_dir="$3"

  if ! _port_registry_lock; then
    return 1
  fi

  # Ensure registry file exists
  mkdir -p "$(dirname "$HATCH_PORT_REGISTRY")"
  touch "$HATCH_PORT_REGISTRY"

  # Remove existing entry for this workspace (if re-running setup)
  local tmp_file="${HATCH_PORT_REGISTRY}.tmp"
  grep -Fv $'\t'"${workspace_name}"$'\t' "$HATCH_PORT_REGISTRY" > "$tmp_file" 2>/dev/null || true

  # Add new entry
  printf '%s\t%s\t%s\t%s\t%s\n' "$base_port" "$workspace_name" "$project_dir" "$(date +%s)" "$$" >> "$tmp_file"
  mv "$tmp_file" "$HATCH_PORT_REGISTRY"

  _port_registry_unlock
}

# _port_registry_release WORKSPACE_NAME
# Removes this workspace's entry from the registry
_port_registry_release() {
  local workspace_name="$1"

  if ! _port_registry_lock; then
    return 1
  fi

  if [[ -f "$HATCH_PORT_REGISTRY" ]]; then
    local tmp_file="${HATCH_PORT_REGISTRY}.tmp"
    grep -Fv $'\t'"${workspace_name}"$'\t' "$HATCH_PORT_REGISTRY" > "$tmp_file" 2>/dev/null || true
    mv "$tmp_file" "$HATCH_PORT_REGISTRY"
  fi

  _port_registry_unlock
}

# _port_registry_clean
# Removes entries for dead workspaces
# Reads entries under lock, releases lock for liveness checks (which may call
# docker ps), then re-acquires to write back only live entries.
_port_registry_clean() {
  if [[ ! -f "$HATCH_PORT_REGISTRY" ]]; then
    return 0
  fi

  # Phase 1: read entries under lock
  if ! _port_registry_lock; then
    return 1
  fi

  local entries=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    entries="${entries}${line}"$'\n'
  done < "$HATCH_PORT_REGISTRY"

  _port_registry_unlock

  # Phase 2: check liveness without holding the lock (docker ps can be slow)
  local live_entries=""
  local removed=0

  while IFS=$'\t' read -r reg_port reg_workspace reg_dir reg_ts reg_pid; do
    [[ -z "$reg_port" ]] && continue
    if _registry_entry_alive "$reg_dir" "$reg_pid"; then
      live_entries="${live_entries}$(printf '%s\t%s\t%s\t%s\t%s' "$reg_port" "$reg_workspace" "$reg_dir" "$reg_ts" "$reg_pid")"$'\n'
    else
      removed=$((removed + 1))
    fi
  done <<< "$entries"

  # Phase 3: write back under lock
  if [[ $removed -gt 0 ]]; then
    if ! _port_registry_lock; then
      return 1
    fi

    local tmp_file="${HATCH_PORT_REGISTRY}.tmp"
    printf '%s' "$live_entries" > "$tmp_file"
    mv "$tmp_file" "$HATCH_PORT_REGISTRY"
    _port_registry_unlock

    _info "Cleaned $removed stale registry entries"
  fi
}

# _port_registry_list
# Prints registry contents with alive/dead status
_port_registry_list() {
  if [[ ! -f "$HATCH_PORT_REGISTRY" ]] || [[ ! -s "$HATCH_PORT_REGISTRY" ]]; then
    echo "  (empty)"
    return
  fi

  while IFS=$'\t' read -r reg_port reg_workspace reg_dir reg_ts reg_pid; do
    [[ -z "$reg_port" ]] && continue
    local status="dead"
    if _registry_entry_alive "$reg_dir" "$reg_pid"; then
      status="alive"
    fi
    echo "  $reg_workspace: base=$reg_port dir=$reg_dir ($status)"
  done < "$HATCH_PORT_REGISTRY"
}

# ---------------------------------------------------------------------------
# Port Generation
# ---------------------------------------------------------------------------

# hatch_generate_ports WORKSPACE_NAME PROJECT_NAME
# Generates BASE_PORT using MD5 hash algorithm with collision probing
# If workspace_name == project_name: use DEFAULT_BASE_PORT (from manifest, default 1481)
# If workspace_name != project_name: hash-based port block (range 10000-60000, spacing 20)
#   with linear probing against the port registry to avoid collisions
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
    local spacing=$HATCH_PORT_SPACING
    local num_buckets=$((port_range / spacing))

    BASE_PORT=$(( (hash_decimal % num_buckets) * spacing + min_port ))

    # Probe for collisions against the port registry
    local probe=0
    local max_probes=10
    while _port_registry_conflict "$BASE_PORT" "$workspace_name" && [[ $probe -lt $max_probes ]]; do
      probe=$((probe + 1))
      local bucket=$(( ((hash_decimal + probe) % num_buckets) ))
      BASE_PORT=$(( bucket * spacing + min_port ))
      _info "Registry conflict, probing alternative base port: $BASE_PORT"
    done

    if [[ $probe -ge $max_probes ]]; then
      _warn "Could not avoid registry conflicts after $max_probes probes (proceeding anyway)"
    fi

    _info "Generated base port for workspace '$workspace_name': $BASE_PORT"
  fi

  export BASE_PORT

  # Claim this port in the registry (best-effort, non-fatal on failure)
  _port_registry_claim "$BASE_PORT" "$workspace_name" "$PWD" 2>/dev/null || \
    _warn "Could not update port registry (non-fatal)"
}

# ---------------------------------------------------------------------------
# Port Allocation
# ---------------------------------------------------------------------------

# _allocate_docker_service SERVICE_SPEC OFFSET LABEL
# Allocates host ports for a Docker service spec (name:port or name:port1,port2)
# Sets PORT_<name>, HATCH_PORT_<name>, and HATCH_PORTMAP_<name>_<cport> variables
# Sets _ALLOC_NEXT_OFFSET to (offset + number_of_ports_consumed)
# IMPORTANT: Must be called directly (not via $(...)) so exports propagate
_allocate_docker_service() {
  local service_spec="$1"
  local offset="$2"
  local label="$3"

  local service_name container_ports_str safe_name
  service_name=$(echo "$service_spec" | cut -d: -f1)
  container_ports_str=$(echo "$service_spec" | cut -d: -f2)
  safe_name=$(_sanitize_var_name "$service_name")

  # Split container ports by comma
  IFS=',' read -ra container_ports <<< "$container_ports_str"
  local port_count=${#container_ports[@]}

  # Primary port variable (first container port, backward compatible)
  local primary_port=$((BASE_PORT + offset))
  eval "PORT_${safe_name}=${primary_port}"
  eval "HATCH_PORT_${safe_name}=${primary_port}"
  export "PORT_${safe_name}" "HATCH_PORT_${safe_name}"

  # Per-container-port mappings
  local idx=0
  for cport in "${container_ports[@]}"; do
    local host_port=$((BASE_PORT + offset + idx))
    eval "HATCH_PORTMAP_${safe_name}_${cport}=${host_port}"
    export "HATCH_PORTMAP_${safe_name}_${cport}"
    idx=$((idx + 1))
  done

  if [[ $port_count -gt 1 ]]; then
    _info "Allocated ports for $label '$service_name': $primary_port-$((primary_port + port_count - 1)) (container ports: $container_ports_str)"
  else
    _info "Allocated port for $label '$service_name': $primary_port (container port: $container_ports_str)"
  fi

  # Return new offset via variable (not stdout, to avoid subshell)
  _ALLOC_NEXT_OFFSET=$((offset + port_count))
}

# hatch_allocate_ports
# Reads DOCKER_SERVICES, DOCKER_EXTRAS, DEV_SERVERS from manifest
# Assigns port offsets and sets port variables
# Docker services get sequential offsets starting from 0
# Docker extras continue after services
# Dev servers use their declared port_offset
# Sets variables: PORT_<name>, HATCH_PORT_<name>, HATCH_PORTMAP_<name>_<cport>
hatch_allocate_ports() {
  if [[ -z "${BASE_PORT:-}" ]]; then
    _die "BASE_PORT not set. Call hatch_generate_ports first."
  fi

  local offset=0

  # Process Docker services first
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    _allocate_docker_service "$service_spec" "$offset" "docker service"
    offset=$_ALLOC_NEXT_OFFSET
  done < <(_parse_services DOCKER_SERVICES)

  # Process Docker extras (continue offset sequence)
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    _allocate_docker_service "$service_spec" "$offset" "docker extra"
    offset=$_ALLOC_NEXT_OFFSET
  done < <(_parse_services DOCKER_EXTRAS)

  # Process dev servers (use their declared port_offset)
  while IFS= read -r server_spec; do
    [[ -z "$server_spec" ]] && continue

    # Parse format: "name:directory:command:port_offset"
    local name port_offset allocated_port
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

# ---------------------------------------------------------------------------
# Port Resolution and Checking
# ---------------------------------------------------------------------------

# hatch_resolve_port SERVICE_NAME
# Returns the allocated port for a named service
# Usage: PORT=$(hatch_resolve_port postgres)
hatch_resolve_port() {
  local service_name="$1"
  local safe_name
  safe_name=$(_sanitize_var_name "$service_name")
  local var_name="HATCH_PORT_${safe_name}"
  local port="${!var_name:-}"

  if [[ -z "$port" ]]; then
    _warn "No port allocated for service: $service_name"
    return 1
  fi

  echo "$port"
}

# hatch_check_ports
# Checks all allocated ports for availability
# Returns 0 if all available, 1 if any conflict
# Prints conflicts with diagnostics to stderr
hatch_check_ports() {
  local has_conflict=0

  # Check all unique ports from HATCH_PORTMAP_* (covers multi-port services)
  local checked_ports=""
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^HATCH_PORTMAP_ ]]; then
      local label=${var_name#HATCH_PORTMAP_}

      if _check_port "$var_value"; then
        _error "Port conflict: $label (port $var_value) is already in use"
        _report_port_user "$var_value"
        has_conflict=1
      fi
      checked_ports="${checked_ports}:${var_value}:"
    fi
  done < <(env | grep '^HATCH_PORTMAP_' | sort)

  # Also check HATCH_PORT_* for dev servers (they don't have PORTMAP entries)
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^HATCH_PORT_ ]]; then
      # Skip if already checked via PORTMAP
      if [[ "$checked_ports" == *":${var_value}:"* ]]; then
        continue
      fi
      local svc=${var_name#HATCH_PORT_}

      if _check_port "$var_value"; then
        _error "Port conflict: $svc (port $var_value) is already in use"
        _report_port_user "$var_value"
        has_conflict=1
      fi
    fi
  done < <(env | grep '^HATCH_PORT_' | sort)

  if [[ $has_conflict -eq 1 ]]; then
    _error "Port conflicts detected. Stop conflicting services or choose a different workspace name."
    return 1
  fi

  _success "All allocated ports are available"
  return 0
}

# _port_owned_by_workspace PORT WORKSPACE_NAME
# Returns 0 if the port is held by a Docker container belonging to this workspace
_port_owned_by_workspace() {
  local port="$1"
  local workspace_name="$2"

  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi

  # Check if any of this workspace's containers map this port
  local container
  while IFS= read -r container; do
    [[ -z "$container" ]] && continue
    if docker port "$container" 2>/dev/null | grep -q ":${port}$"; then
      return 0
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -F "${workspace_name}-")

  return 1
}

# hatch_check_ports_smart WORKSPACE_NAME
# Like hatch_check_ports but tolerates ports owned by this workspace's Docker containers
# Used when Docker may already be running for this workspace
hatch_check_ports_smart() {
  local workspace_name="$1"
  local has_conflict=0

  # Check all unique ports from HATCH_PORTMAP_*
  local checked_ports=""
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^HATCH_PORTMAP_ ]]; then
      local label=${var_name#HATCH_PORTMAP_}

      if _check_port "$var_value"; then
        if _port_owned_by_workspace "$var_value" "$workspace_name"; then
          _info "Port $var_value ($label) in use by own container (OK)"
        else
          _error "Port conflict: $label (port $var_value) is already in use"
          _report_port_user "$var_value"
          has_conflict=1
        fi
      fi
      checked_ports="${checked_ports}:${var_value}:"
    fi
  done < <(env | grep '^HATCH_PORTMAP_' | sort)

  # Also check HATCH_PORT_* for dev servers
  while IFS='=' read -r var_name var_value; do
    if [[ "$var_name" =~ ^HATCH_PORT_ ]]; then
      if [[ "$checked_ports" == *":${var_value}:"* ]]; then
        continue
      fi
      local svc=${var_name#HATCH_PORT_}

      if _check_port "$var_value"; then
        if _port_owned_by_workspace "$var_value" "$workspace_name"; then
          _info "Port $var_value ($svc) in use by own container (OK)"
        else
          _error "Port conflict: $svc (port $var_value) is already in use"
          _report_port_user "$var_value"
          has_conflict=1
        fi
      fi
    fi
  done < <(env | grep '^HATCH_PORT_' | sort)

  if [[ $has_conflict -eq 1 ]]; then
    _error "Port conflicts detected. Stop conflicting services or choose a different workspace name."
    return 1
  fi

  _success "All allocated ports are available"
  return 0
}
