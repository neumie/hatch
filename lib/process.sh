#!/usr/bin/env bash
# process.sh - Manifest-driven process management for dev servers
# Depends on: core.sh, manifest.sh, ports.sh

# hatch_start_servers [services...]
# Reads DEV_SERVERS from manifest. Format per entry: "name:directory:command:port_offset"
# If services args given, start only those matching by name
# If no args, start all
# For each server: check port, replace {PORT} in command with actual port, start in subshell
# Save PIDs and port info to .hatch/pids
# Print startup URL for each
hatch_start_servers() {
  local target_services=("$@")
  local has_targets=0

  if [[ ${#target_services[@]} -gt 0 ]]; then
    has_targets=1
  fi

  # Create .hatch directory if it doesn't exist
  mkdir -p .hatch

  # Clear existing pid file
  : > .hatch/pids

  _header "Starting dev servers"

  # Process dev servers
  while IFS= read -r server_spec; do
    [[ -z "$server_spec" ]] && continue

    # Parse format: "name:directory:command:port_offset"
    local name directory command port_offset
    name=$(echo "$server_spec" | cut -d: -f1)
    directory=$(echo "$server_spec" | cut -d: -f2)
    command=$(echo "$server_spec" | cut -d: -f3)
    port_offset=$(echo "$server_spec" | rev | cut -d: -f1 | rev)

    # Skip if target services specified and this isn't one of them
    if [[ $has_targets -eq 1 ]]; then
      local matched=0
      local target
      for target in "${target_services[@]}"; do
        if [[ "$target" == "$name" ]]; then
          matched=1
          break
        fi
      done
      if [[ $matched -eq 0 ]]; then
        continue
      fi
    fi

    # Resolve port
    local port
    port=$(hatch_resolve_port "$name") || _die "Failed to resolve port for $name"

    # Check if port is available
    if _check_port "$port"; then
      _error "Port $port for service '$name' is already in use"
      continue
    fi

    # Replace {PORT} placeholder in command
    local resolved_command
    resolved_command=$(echo "$command" | sed "s/{PORT}/$port/g")

    _info "Starting $name in $directory on port $port"

    # Start server in background (use absolute log path since we cd into directory)
    local log_file="$PWD/.hatch/${name}.log"
    (
      cd "$directory" || exit 1
      _pkg_run $resolved_command > "$log_file" 2>&1
    ) &

    local pid=$!

    # Save PID and info
    echo "$name:$pid:$port:$directory" >> .hatch/pids

    _success "Started $name (PID: $pid) - http://localhost:$port"
  done < <(_parse_services DEV_SERVERS)

  if [[ ! -s .hatch/pids ]]; then
    _warn "No servers started"
  fi
}

# hatch_run_servers [services...]
# Like start_servers but runs in foreground - sets up trap for INT/TERM to kill all children
# Used by `hatch run`
hatch_run_servers() {
  local pids=()

  # Setup trap to kill all child processes on exit
  trap 'hatch_stop_servers; exit' INT TERM

  # Start servers and collect PIDs
  hatch_start_servers "$@"

  # Read PIDs from file
  if [[ -f .hatch/pids ]]; then
    while IFS=: read -r name pid port directory; do
      [[ -z "$pid" ]] && continue
      pids+=("$pid")
    done < .hatch/pids
  fi

  if [[ ${#pids[@]} -eq 0 ]]; then
    _warn "No servers to run"
    return 0
  fi

  _info "Running in foreground. Press Ctrl+C to stop all servers."

  # Wait for all background processes
  wait
}

# hatch_stop_servers
# Reads .hatch/pids, kills each PID and its children, removes pid file
hatch_stop_servers() {
  if [[ ! -f .hatch/pids ]]; then
    _warn "No running servers found (.hatch/pids does not exist)"
    return 0
  fi

  _header "Stopping dev servers"

  while IFS=: read -r name pid port directory; do
    [[ -z "$pid" ]] && continue

    if kill -0 "$pid" 2>/dev/null; then
      _info "Stopping $name (PID: $pid)"

      # Kill child processes first
      pkill -P "$pid" 2>/dev/null || true

      # Kill main process
      kill "$pid" 2>/dev/null || true

      # Wait a moment for graceful shutdown
      sleep 0.5

      # Force kill if still running
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi

      _success "Stopped $name"
    else
      _warn "$name (PID: $pid) is not running"
    fi
  done < .hatch/pids

  # Remove pid file
  rm -f .hatch/pids
  _success "All servers stopped"
}

# hatch_server_status
# Reads .hatch/pids, checks each PID, prints running/stopped status and URLs
hatch_server_status() {
  if [[ ! -f .hatch/pids ]]; then
    _info "No servers registered (.hatch/pids does not exist)"
    return 0
  fi

  _header "Server status"

  local has_running=0

  while IFS=: read -r name pid port directory; do
    [[ -z "$pid" ]] && continue

    if kill -0 "$pid" 2>/dev/null; then
      _success "$name (PID: $pid) - RUNNING - http://localhost:$port"
      has_running=1
    else
      _warn "$name (PID: $pid) - STOPPED"
    fi
  done < .hatch/pids

  if [[ $has_running -eq 0 ]]; then
    _info "No servers are currently running"
  fi
}
