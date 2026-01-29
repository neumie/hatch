#!/usr/bin/env bash
# core.sh - Platform abstraction and utility library for hatch
# This file is sourced by all hatch scripts.

set -euo pipefail

# Platform Detection
case "$OSTYPE" in
  darwin*)
    HATCH_PLATFORM="darwin"
    ;;
  linux*)
    HATCH_PLATFORM="linux"
    ;;
  *)
    echo "Unsupported platform: $OSTYPE" >&2
    exit 1
    ;;
esac

# Directory Constants
HATCH_HOME="${HATCH_HOME:-$HOME/.hatch}"
HATCH_LIB="$HATCH_HOME/lib"
HATCH_SECRETS="${HATCH_SECRETS:-$HATCH_HOME/secrets}"
HATCH_DATA="${HATCH_DATA:-$HATCH_HOME/data}"
HATCH_PROJECTS="$HATCH_HOME/projects"

# Cross-Platform Wrapper Functions

# sed -i wrapper (handles macOS requiring empty string for -i)
_sed_i() {
  if [[ "$HATCH_PLATFORM" == "darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# MD5 hash of a string
_md5() {
  if [[ "$HATCH_PLATFORM" == "darwin" ]]; then
    md5 -q -s "$1"
  else
    echo -n "$1" | md5sum | cut -d' ' -f1
  fi
}

# Open URL in default browser
_open_url() {
  if [[ "$HATCH_PLATFORM" == "darwin" ]]; then
    open "$1"
  else
    xdg-open "$1"
  fi
}

# Check if port is in use (returns 0 if in use, 1 if available)
_check_port() {
  if lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  elif [[ "$HATCH_PLATFORM" == "linux" ]] && command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -qE ":$1\b" && return 0
  fi
  # Docker port bindings may not appear in lsof/ss:
  # - macOS: Docker Desktop runs in a VM with a proxy process
  # - Linux: Docker may use iptables DNAT rules instead of docker-proxy
  # Check Docker container port mappings directly.
  if command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(0\.0\.0\.0:|:::|\[::\]:)$1->"; then
      return 0
    fi
  fi
  return 1
}

# _report_port_user PORT
# Prints diagnostic information about what process or container is using a port
_report_port_user() {
  local port="$1"

  # Try lsof (gives PID and process name on both platforms)
  if command -v lsof >/dev/null 2>&1; then
    local lsof_output
    lsof_output=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null | tail -n +2 | head -1)
    if [[ -n "$lsof_output" ]]; then
      local proc_name proc_pid
      proc_name=$(echo "$lsof_output" | awk '{print $1}')
      proc_pid=$(echo "$lsof_output" | awk '{print $2}')
      _error "  -> Process: $proc_name (PID $proc_pid)"
      _error "  -> To free: kill $proc_pid"
      return
    fi
  fi

  # Try ss on Linux
  if [[ "$HATCH_PLATFORM" == "linux" ]] && command -v ss >/dev/null 2>&1; then
    local ss_output
    ss_output=$(ss -tlnp 2>/dev/null | grep -E ":$port\b" | head -1)
    if [[ -n "$ss_output" ]]; then
      _error "  -> $ss_output"
      return
    fi
  fi

  # Try Docker container lookup
  if command -v docker >/dev/null 2>&1; then
    local docker_match
    docker_match=$(docker ps --format '{{.Names}}: {{.Ports}}' 2>/dev/null | grep -E ":$port->" | head -1)
    if [[ -n "$docker_match" ]]; then
      _error "  -> Docker container: $docker_match"
      return
    fi
  fi

  # Check hatch port registry
  if [[ -f "${HATCH_HOME:-$HOME/.hatch}/port-registry" ]]; then
    while IFS=$'\t' read -r reg_port reg_workspace _ _ _; do
      local reg_end=$((reg_port + ${HATCH_PORT_SPACING:-20}))
      if [[ "$port" -ge "$reg_port" ]] && [[ "$port" -lt "$reg_end" ]]; then
        _error "  -> Hatch workspace '$reg_workspace' (base port: $reg_port)"
        return
      fi
    done < "${HATCH_HOME:-$HOME/.hatch}/port-registry"
  fi

  _error "  -> Could not identify what is using port $port"
}

# _kill_conflicting_ports WORKSPACE_NAME
# Kills processes on ports that conflict with allocated hatch ports,
# skipping ports owned by this workspace's Docker containers.
_kill_conflicting_ports() {
  local workspace_name="$1"
  local killed=0

  # Collect all allocated ports (deduplicated)
  local ports=()
  local checked=""
  while IFS='=' read -r var_name var_value; do
    ports+=("$var_value")
    checked="${checked}:${var_value}:"
  done < <(env | grep '^HATCH_PORTMAP_' | sort)
  while IFS='=' read -r var_name var_value; do
    if [[ "$checked" == *":${var_value}:"* ]]; then
      continue
    fi
    ports+=("$var_value")
    checked="${checked}:${var_value}:"
  done < <(env | grep '^HATCH_PORT_' | sort)

  for port in "${ports[@]}"; do
    # Port is free, nothing to kill
    if ! _check_port "$port"; then
      continue
    fi
    # Skip ports owned by our own workspace containers
    if _port_owned_by_workspace "$port" "$workspace_name" 2>/dev/null; then
      continue
    fi
    # Try to get the PID via lsof
    if command -v lsof >/dev/null 2>&1; then
      local pid
      pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
      if [[ -n "$pid" ]]; then
        _info "Killing PID $pid on port $port"
        kill "$pid" 2>/dev/null && sleep 0.5 || kill -9 "$pid" 2>/dev/null || true
        killed=$((killed + 1))
        continue
      fi
    fi
    _warn "Could not find PID for port $port, skipping"
  done

  if [[ $killed -gt 0 ]]; then
    # Give processes a moment to release ports
    sleep 1
    _success "Killed $killed conflicting process(es)"
  fi
}

# _find_conflicting_workspaces WORKSPACE_NAME
# Prints the names of other workspaces whose port ranges overlap with
# the current workspace's allocated ports. Returns 1 if none found.
_find_conflicting_workspaces() {
  local workspace_name="$1"
  local registry="${HATCH_HOME:-$HOME/.hatch}/port-registry"
  local found=()

  [[ -f "$registry" ]] || return 1

  # Collect all allocated ports for the current workspace
  local ports=()
  while IFS='=' read -r _ var_value; do
    ports+=("$var_value")
  done < <(env | grep '^HATCH_PORTMAP_\|^HATCH_PORT_' | sort)

  for port in "${ports[@]}"; do
    # Port is free, no conflict
    ! _check_port "$port" && continue

    while IFS=$'\t' read -r reg_port reg_workspace _ _ _; do
      [[ "$reg_workspace" == "$workspace_name" ]] && continue
      local reg_end=$((reg_port + ${HATCH_PORT_SPACING:-20}))
      if [[ "$port" -ge "$reg_port" ]] && [[ "$port" -lt "$reg_end" ]]; then
        # Deduplicate
        local already=false
        for f in "${found[@]+"${found[@]}"}"; do
          [[ "$f" == "$reg_workspace" ]] && already=true && break
        done
        $already || found+=("$reg_workspace")
      fi
    done < "$registry"
  done

  if [[ ${#found[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${found[@]}"
}

# Docker host hostname for container-to-host communication
_docker_host() {
  if [[ "$HATCH_PLATFORM" == "darwin" ]]; then
    echo "host.docker.internal"
  else
    echo "172.17.0.1"
  fi
}

# Output Helpers

# Detect if we should use colors (stdout is a terminal)
if [[ -t 1 ]]; then
  _COLOR_BLUE=$(tput setaf 4)
  _COLOR_YELLOW=$(tput setaf 3)
  _COLOR_RED=$(tput setaf 1)
  _COLOR_GREEN=$(tput setaf 2)
  _COLOR_BOLD=$(tput bold)
  _COLOR_RESET=$(tput sgr0)
else
  _COLOR_BLUE=""
  _COLOR_YELLOW=""
  _COLOR_RED=""
  _COLOR_GREEN=""
  _COLOR_BOLD=""
  _COLOR_RESET=""
fi

_log() {
  echo "$@"
}

_info() {
  echo "${_COLOR_BLUE}[info]${_COLOR_RESET} $*"
}

_warn() {
  echo "${_COLOR_YELLOW}[warn]${_COLOR_RESET} $*"
}

_error() {
  echo "${_COLOR_RED}[error]${_COLOR_RESET} $*" >&2
}

_success() {
  echo "${_COLOR_GREEN}[ok]${_COLOR_RESET} $*"
}

_header() {
  echo "${_COLOR_BOLD}=== $* ===${_COLOR_RESET}"
}

_die() {
  _error "$@"
  exit 1
}

# Dependency Checking

_require() {
  local cmd="$1"
  local hint="${2:-}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    _error "Required command not found: $cmd"
    if [[ -n "$hint" ]]; then
      _error "$hint"
    fi
    exit 1
  fi
}

# Package Manager Helpers

_pkg_run() {
  local cmd="$1"
  shift

  case "${PACKAGE_MANAGER:-npm}" in
    yarn)
      yarn "$cmd" "$@"
      ;;
    npm)
      # Check if it's a script in package.json or a binary
      if npm run | grep -q "^  $cmd$" 2>/dev/null; then
        npm run "$cmd" -- "$@"
      else
        npx "$cmd" "$@"
      fi
      ;;
    pnpm)
      pnpm "$cmd" "$@"
      ;;
    bun)
      bun "$cmd" "$@"
      ;;
    none)
      "$cmd" "$@"
      ;;
    *)
      _die "Unknown package manager: ${PACKAGE_MANAGER:-npm}"
      ;;
  esac
}

_pkg_install() {
  case "${PACKAGE_MANAGER:-npm}" in
    yarn)
      yarn install
      ;;
    npm)
      npm install
      ;;
    pnpm)
      pnpm install
      ;;
    bun)
      bun install
      ;;
    none)
      _warn "PACKAGE_MANAGER=none, skipping install"
      ;;
    *)
      _die "Unknown package manager: ${PACKAGE_MANAGER:-npm}"
      ;;
  esac
}
