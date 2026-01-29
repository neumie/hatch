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
    ss -tlnp 2>/dev/null | grep -q ":$1 " && return 0
  fi
  return 1
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
