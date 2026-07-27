#!/usr/bin/env bash
set -euo pipefail
# process.sh - Manifest-driven process management for dev servers
# Depends on: core.sh, manifest.sh, ports.sh

# Stable ownership handle inherited by every Hatch-started service descendant.
# Unlike PID files, an open descriptor survives re-parenting and cannot become
# stale via PID reuse. lsof resolves the exact file inode, so workspace paths
# containing spaces or regex metacharacters are safe.
_hatch_owner_file() {
  printf '%s/.hatch/owner' "$(pwd -P)"
}

_hatch_service_owner_file() {
  printf '%s/.hatch/owners/%s' "$(pwd -P)" "$1"
}

_owner_file_pids() {
  local owner_file="$1"
  [[ -f "$owner_file" ]] || return 0
  lsof -t "$owner_file" 2>/dev/null | sort -u
}

_pid_holds_owner_file() {
  local pid="$1"
  local owner_file="$2"
  [[ -f "$owner_file" ]] || return 1
  lsof -t -a -p "$pid" "$owner_file" 2>/dev/null | grep -qx "$pid"
}

# _pid_is_hatch_owned PID
# Verify that a live process still holds this workspace's ownership descriptor.
_pid_is_hatch_owned() {
  _pid_holds_owner_file "$1" "$(_hatch_owner_file)"
}

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
      local service_owner_file
      service_owner_file=$(_hatch_service_owner_file "$name")
      _info "Stopping $name (PID: $pid)"
      if kill -0 "$pid" 2>/dev/null; then
        if _pid_holds_owner_file "$pid" "$service_owner_file"; then
          # Kill via tree walk (not process group — targeted stop must not affect other servers)
          _kill_tree "$pid"
          sleep 0.5
          if kill -0 "$pid" 2>/dev/null; then
            _kill_tree "$pid" 9
          fi
        else
          _warn "Skipping stale or unowned PID $pid for $name"
        fi
      fi
      if [[ -n "$port" ]] && _check_port "$port"; then
        _force_free_port "$port" "$service_owner_file"
      fi
      _sweep_owner_file "$service_owner_file"
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

  # Create runtime state and the stable process-ownership inode. Truncating an
  # existing file preserves its inode for services still winding down.
  mkdir -p .hatch/owners
  : > .hatch/owner

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
    local name directory command
    name=$(echo "$server_spec" | cut -d: -f1)
    directory=$(echo "$server_spec" | cut -d: -f2)
    command=$(echo "$server_spec" | cut -d: -f3)

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
    local resolved_command owner_file service_owner_file
    resolved_command=${command//\{PORT\}/$port}
    owner_file=$(_hatch_owner_file)
    service_owner_file=$(_hatch_service_owner_file "$name")
    : > "$service_owner_file"

    _info "Starting $name in $directory on port $port"

    # Start server in background, detached so it survives parent exit. Every
    # descendant inherits the workspace and per-service ownership descriptors,
    # including tools that re-parent after the PID file is lost.
    local log_file="$PWD/.hatch/${name}.log"
    (
      cd "$directory" || exit 1
      # The manifest command is intentionally shell-split into argv here.
      # shellcheck disable=SC2086
      _pkg_run $resolved_command 8<"$owner_file" 9<"$service_owner_file" > "$log_file" 2>&1
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
# Uses three ownership-checked layers to handle orphaned descendants:
#   1. Recursive tree kill via pgrep -P
#   2. Port-based sweep via lsof (only Hatch-marked listeners)
#   3. Ownership-marker sweep (catches daemonized/non-listening descendants)
hatch_stop_servers() {
  if [[ ! -f .hatch/pids ]]; then
    _warn "PID metadata is missing; sweeping workspace processes instead"
    hatch_sweep_orphans
    _success "Workspace orphan sweep complete"
    return 0
  fi

  _header "Stopping dev servers"

  while IFS=: read -r name pid port directory; do
    [[ -z "$pid" ]] && continue

    _info "Stopping $name (PID: $pid)"

    if kill -0 "$pid" 2>/dev/null; then
      if _pid_is_hatch_owned "$pid"; then
        # Layer 1: Kill the tree via parent-child walk. Do not signal the
        # process group: Hatch does not own it, and it may include the user's
        # terminal or unrelated tools.
        _kill_tree "$pid"

        # Wait a moment for graceful shutdown
        sleep 0.5

        # Force kill if root is still running
        if kill -0 "$pid" 2>/dev/null; then
          _kill_tree "$pid" 9
        fi
      else
        _warn "Skipping stale or unowned PID $pid for $name"
      fi
    fi

    # Layer 2: Sweep the port for orphaned processes (e.g. esbuild)
    if [[ -n "$port" ]] && _check_port "$port"; then
      _force_free_port "$port"
    fi

    # Layer 3: Kill any remaining descendants attributed to this service.
    # Catches non-listening orphans (e.g. esbuild bundler) that escaped layers 1-2
    # because they called setsid() and don't hold a port.
    if [[ -n "$directory" ]]; then
      _sweep_owner_file "$(_hatch_service_owner_file "$name")"
    fi

    _success "Stopped $name"
  done < .hatch/pids

  # Remove pid file
  rm -f .hatch/pids

  # Final sweep: catch any remaining orphans from the project root
  # (covers processes spawned from root node_modules/ that individual
  # server-directory sweeps above may have missed)
  _sweep_workspace_processes "."

  _success "All servers stopped"
}

# hatch_sweep_orphans
# Standalone orphan sweep that works without .hatch/pids. It targets only
# processes holding the ownership descriptor opened by hatch_start_servers.
# Safe to call repeatedly and cannot match paths from unrelated command lines.
hatch_sweep_orphans() {
  _sweep_workspace_processes "."
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

# _force_free_port PORT [OWNER_FILE]
# Non-interactive: kills only listeners holding the requested ownership file
# (workspace-wide by default). A stale port record must never terminate a
# process that merely reused the same port or belongs to a sibling service.
_force_free_port() {
  local port="$1"
  local owner_file="${2:-$(_hatch_owner_file)}"
  local pids p killed_any=0
  pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  [[ -z "$pids" ]] && return 0

  for p in $pids; do
    if _pid_holds_owner_file "$p" "$owner_file"; then
      _kill_tree "$p"
      killed_any=1
    else
      _warn "Skipping unowned listener PID $p on stale port $port"
    fi
  done
  [[ $killed_any -eq 0 ]] && return 0
  sleep 0.5

  # Force kill only owned survivors.
  pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  for p in $pids; do
    if _pid_holds_owner_file "$p" "$owner_file"; then
      _kill_tree "$p" 9
    fi
  done

  # Wait for an owned listener to release the port (up to 3s).
  local attempts=0
  while _check_port "$port" && [[ $attempts -lt 6 ]]; do
    sleep 0.5
    attempts=$((attempts + 1))
  done
}

# _sweep_owner_file FILE
# Kill every marked anchor and its current descendants. Tree walking matters for
# children that deliberately close inherited descriptors but remain attached to
# an owned wrapper.
_sweep_owner_file() {
  local owner_file="$1"
  local owner_pids p
  owner_pids=$(_owner_file_pids "$owner_file") || true
  [[ -z "$owner_pids" ]] && return 0

  for p in $owner_pids; do
    [[ "$p" == "$$" ]] && continue
    _kill_tree "$p"
  done
  sleep 0.3

  owner_pids=$(_owner_file_pids "$owner_file") || true
  for p in $owner_pids; do
    [[ "$p" == "$$" ]] && continue
    _kill_tree "$p" 9
  done
}

# _sweep_workspace_processes DIRECTORY
# Last-resort cleanup by inherited ownership descriptor. DIRECTORY is retained in
# the API for compatibility with existing callers; ownership is workspace-wide.
_sweep_workspace_processes() {
  : "${1:-.}"
  _sweep_owner_file "$(_hatch_owner_file)"
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

    if kill -0 "$pid" 2>/dev/null \
      && _pid_holds_owner_file "$pid" "$(_hatch_service_owner_file "$name")"; then
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
