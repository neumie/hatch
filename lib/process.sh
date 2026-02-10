#!/usr/bin/env bash
set -euo pipefail
# process.sh - Manifest-driven process management for dev servers
# Depends on: core.sh, manifest.sh, ports.sh

# _stop_targeted_servers service1 [service2 ...]
# Stops only the named servers from .hatch/pids, preserving other entries.
_stop_targeted_servers() {
  local targets=("$@")
  local tmp_pids
  tmp_pids=$(mktemp)

  while IFS=: read -r name pid port directory; do
    [[ -z "$pid" ]] && continue

    local should_stop=0
    local target
    for target in "${targets[@]}"; do
      if [[ "$target" == "$name" ]]; then
        should_stop=1
        break
      fi
    done

    if [[ $should_stop -eq 1 ]]; then
      _info "Stopping $name (PID: $pid)"
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM -"$pid" 2>/dev/null || true
        _kill_tree "$pid"
        sleep 0.5
        if kill -0 "$pid" 2>/dev/null; then
          kill -KILL -"$pid" 2>/dev/null || true
          _kill_tree "$pid" 9
        fi
      fi
      if [[ -n "$port" ]] && _check_port "$port"; then
        _force_free_port "$port"
      fi
      _success "Stopped $name"
    else
      # Preserve this entry
      echo "$name:$pid:$port:$directory" >> "$tmp_pids"
    fi
  done < .hatch/pids

  mv "$tmp_pids" .hatch/pids
}

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

  # Stop existing servers before starting new ones
  if [[ -f .hatch/pids ]] && [[ -s .hatch/pids ]]; then
    if [[ $has_targets -eq 1 ]]; then
      # Only stop targeted servers, preserve others
      _stop_targeted_servers "${target_services[@]}"
    else
      hatch_stop_servers
      # Clear pid file only when restarting all
      : > .hatch/pids
    fi
  else
    : > .hatch/pids
  fi

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

    # Check if port is available — offer to reclaim if occupied
    if _check_port "$port"; then
      _try_reclaim_port "$port" "Port $port for '$name' is in use by" || true
      if _check_port "$port"; then
        _error "Port $port for service '$name' is already in use"
        _report_port_user "$port"
        continue
      fi
    fi

    # Replace {PORT} placeholder in command
    local resolved_command
    resolved_command=$(echo "$command" | sed "s/{PORT}/$port/g")

    _info "Starting $name in $directory on port $port"

    # Start server in background, detached so it survives parent exit
    local log_file="$PWD/.hatch/${name}.log"
    (
      cd "$directory" || exit 1
      _pkg_run $resolved_command > "$log_file" 2>&1
    ) &

    local pid=$!
    disown "$pid" 2>/dev/null || true

    # Save PID and info
    echo "$name:$pid:$port:$directory" >> .hatch/pids

    _success "Started $name (PID: $pid) - http://localhost:$port?_hatch=$(_urlencode "$WORKSPACE_NAME")"
  done < <(_parse_services DEV_SERVERS)

  if [[ ! -s .hatch/pids ]]; then
    _warn "No servers started"
  fi
}

# hatch_stop_servers
# Reads .hatch/pids, kills each PID and its children, removes pid file.
# Uses four layers of cleanup to handle orphaned descendants:
#   1. Process group kill (catches children that kept the same PGID)
#   2. Recursive tree kill via pgrep -P
#   3. Port-based sweep via lsof (catches orphans still holding the port)
#   4. Workspace path sweep via pgrep -f (catches non-listening orphans like esbuild)
hatch_stop_servers() {
  if [[ ! -f .hatch/pids ]]; then
    _warn "No running servers found (.hatch/pids does not exist)"
    return 0
  fi

  _header "Stopping dev servers"

  while IFS=: read -r name pid port directory; do
    [[ -z "$pid" ]] && continue

    _info "Stopping $name (PID: $pid)"

    if kill -0 "$pid" 2>/dev/null; then
      # Layer 1: Kill the process group (PGID == PID for background subshells)
      kill -TERM -"$pid" 2>/dev/null || true

      # Layer 2: Kill the tree via parent-child walk
      _kill_tree "$pid"

      # Wait a moment for graceful shutdown
      sleep 0.5

      # Force kill if root is still running
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -"$pid" 2>/dev/null || true
        _kill_tree "$pid" 9
      fi
    fi

    # Layer 3: Sweep the port for orphaned processes (e.g. esbuild)
    if [[ -n "$port" ]] && _check_port "$port"; then
      _force_free_port "$port"
    fi

    # Layer 4: Kill any remaining processes spawned from this workspace directory.
    # Catches non-listening orphans (e.g. esbuild bundler) that escaped layers 1-3
    # because they called setsid() and don't hold a port.
    if [[ -n "$directory" ]]; then
      _sweep_workspace_processes "$directory"
    fi

    _success "Stopped $name"
  done < .hatch/pids

  # Remove pid file
  rm -f .hatch/pids
  _success "All servers stopped"
}

# _kill_tree PID [SIGNAL]
# Recursively kill a process and all its descendants (depth-first)
_kill_tree() {
  local pid=$1
  local sig=${2:-TERM}
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  local child
  for child in $children; do
    _kill_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# _force_free_port PORT
# Non-interactive: kills whatever process is listening on PORT.
# Used during hatch stop to clean up orphaned descendants (e.g. esbuild)
# that survived the tree kill because their parent-child chain broke.
_force_free_port() {
  local port="$1"
  local pids
  pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  [[ -z "$pids" ]] && return 0

  local p
  for p in $pids; do
    _kill_tree "$p"
  done
  sleep 0.5

  # Force kill any survivors
  pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  for p in $pids; do
    _kill_tree "$p" 9
  done

  # Wait for port to actually be released (up to 3s)
  local attempts=0
  while _check_port "$port" && [[ $attempts -lt 6 ]]; do
    sleep 0.5
    attempts=$((attempts + 1))
  done
}

# _sweep_workspace_processes DIRECTORY
# Last-resort cleanup: finds processes whose binary path lives inside DIRECTORY
# (typically node_modules/.../esbuild) and kills them. Avoids false positives by
# matching only processes whose executable path starts with the absolute workspace dir.
_sweep_workspace_processes() {
  local directory="$1"
  local abs_dir
  abs_dir=$(cd "$directory" 2>/dev/null && pwd) || return 0

  local orphan_pids
  orphan_pids=$(pgrep -f "^${abs_dir}/" 2>/dev/null) || true
  [[ -z "$orphan_pids" ]] && return 0

  local p
  for p in $orphan_pids; do
    # Skip our own shell process
    [[ "$p" == "$$" ]] && continue
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.3

  orphan_pids=$(pgrep -f "^${abs_dir}/" 2>/dev/null) || true
  for p in $orphan_pids; do
    [[ "$p" == "$$" ]] && continue
    kill -KILL "$p" 2>/dev/null || true
  done
}

# _try_reclaim_port PORT [WARNING_PREFIX]
# Finds the process listening on PORT via lsof, warns with the given prefix,
# and interactively offers to kill it. Returns 0 if killed, 1 otherwise.
# Note: lsof -t may return multiple PIDs (fork-based servers, SO_REUSEPORT);
# we take the first and rely on _kill_tree to handle the process tree.
_try_reclaim_port() {
  local port="$1"
  local warn_prefix="${2:-Port $port is in use by}"
  local stale_pid
  stale_pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
  [[ -z "$stale_pid" ]] && return 1

  _warn "${warn_prefix} PID $stale_pid"

  if [[ -t 0 ]]; then
    local confirm
    read -r -p "  Kill PID $stale_pid to free port $port? [y/N] " confirm || confirm=n
    if [[ "$confirm" == "y" ]] || [[ "$confirm" == "Y" ]]; then
      _kill_tree "$stale_pid"
      sleep 0.5
      if kill -0 "$stale_pid" 2>/dev/null; then
        _kill_tree "$stale_pid" 9
        sleep 0.5
      fi
      # Wait for port to actually be released (up to 3s)
      local attempts=0
      while _check_port "$port" && [[ $attempts -lt 6 ]]; do
        sleep 0.5
        attempts=$((attempts + 1))
      done
      return 0
    fi
  else
    _info "Run 'kill $stale_pid' to free port $port"
  fi
  return 1
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
      _success "$name (PID: $pid) - RUNNING - http://localhost:$port?_hatch=$(_urlencode "$WORKSPACE_NAME")"
      has_running=1
    else
      _warn "$name (PID: $pid) - STOPPED"
    fi
  done < .hatch/pids

  if [[ $has_running -eq 0 ]]; then
    _info "No servers are currently running"
  fi
}
