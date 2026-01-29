#!/usr/bin/env bash
# doctor.sh - Check system dependencies

_header "Hatch Doctor"
echo ""
echo "Checking system dependencies..."
echo ""

FAILED=0

# Check bash version
BASH_VERSION_NUM=$(echo "$BASH_VERSION" | cut -d. -f1)
if [[ $BASH_VERSION_NUM -ge 3 ]]; then
  _success "bash: $BASH_VERSION"
else
  _error "bash: $BASH_VERSION (need 3.2+)"
  FAILED=1
fi

# Check docker
if command -v docker >/dev/null 2>&1; then
  DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
  _success "docker: $DOCKER_VERSION"
  
  # Check if docker daemon is running
  if docker info >/dev/null 2>&1; then
    _success "docker daemon: running"
  else
    _warn "docker daemon: not running"
  fi
else
  _error "docker: not found"
  echo "  Install: https://docs.docker.com/get-docker/"
  FAILED=1
fi

# Check docker compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "installed")
  _success "docker compose: $COMPOSE_VERSION"
else
  _error "docker compose: not found"
  echo "  Install with Docker Desktop or: https://docs.docker.com/compose/install/"
  FAILED=1
fi

# Check git
if command -v git >/dev/null 2>&1; then
  GIT_VERSION=$(git --version | cut -d' ' -f3)
  _success "git: $GIT_VERSION"
else
  _error "git: not found"
  echo "  Install: https://git-scm.com/downloads"
  FAILED=1
fi

# Check curl
if command -v curl >/dev/null 2>&1; then
  CURL_VERSION=$(curl --version | head -1 | cut -d' ' -f2)
  _success "curl: $CURL_VERSION"
else
  _error "curl: not found"
  echo "  Install: apt install curl / brew install curl"
  FAILED=1
fi

# Check lsof or ss (for port checking)
if command -v lsof >/dev/null 2>&1; then
  _success "lsof: installed"
elif command -v ss >/dev/null 2>&1; then
  _success "ss: installed (alternative to lsof)"
else
  _warn "lsof/ss: not found (port checking may not work)"
  echo "  Install: apt install lsof / brew install lsof"
fi

# Check package managers if manifest exists
if [[ -f "hatch.conf" ]] || [[ -f "$HOME/.hatch/projects/$(basename "$PWD").conf" ]]; then
  echo ""
  echo "Checking package manager..."
  
  # Try to load manifest
  if [[ -f "hatch.conf" ]]; then
    source "hatch.conf"
  elif [[ -f "$HOME/.hatch/projects/$(basename "$PWD").conf" ]]; then
    source "$HOME/.hatch/projects/$(basename "$PWD").conf"
  fi
  
  case "${PACKAGE_MANAGER:-none}" in
    yarn)
      if command -v yarn >/dev/null 2>&1; then
        YARN_VERSION=$(yarn --version 2>/dev/null || echo "unknown")
        _success "yarn: $YARN_VERSION"
      else
        _error "yarn: not found (required by manifest)"
        echo "  Install: npm install -g yarn"
        FAILED=1
      fi
      ;;
    pnpm)
      if command -v pnpm >/dev/null 2>&1; then
        PNPM_VERSION=$(pnpm --version)
        _success "pnpm: $PNPM_VERSION"
      else
        _error "pnpm: not found (required by manifest)"
        echo "  Install: npm install -g pnpm"
        FAILED=1
      fi
      ;;
    npm)
      if command -v npm >/dev/null 2>&1; then
        NPM_VERSION=$(npm --version)
        _success "npm: $NPM_VERSION"
      else
        _error "npm: not found (required by manifest)"
        echo "  Install: https://nodejs.org/"
        FAILED=1
      fi
      ;;
    bun)
      if command -v bun >/dev/null 2>&1; then
        BUN_VERSION=$(bun --version)
        _success "bun: $BUN_VERSION"
      else
        _error "bun: not found (required by manifest)"
        echo "  Install: curl -fsSL https://bun.sh/install | bash"
        FAILED=1
      fi
      ;;
    none)
      _info "No package manager configured"
      ;;
  esac
fi

# Check port registry
echo ""
echo "Port registry:"
if [[ -f "${HATCH_HOME}/port-registry" ]]; then
  source "$HATCH_LIB/ports.sh" 2>/dev/null || true
  if type _port_registry_list &>/dev/null; then
    _port_registry_list
    _port_registry_clean 2>/dev/null || true
  else
    echo "  (ports.sh not loaded)"
  fi
else
  echo "  (no registry file)"
fi

echo ""
if [[ $FAILED -eq 0 ]]; then
  _success "All checks passed!"
else
  _error "Some checks failed. Install missing dependencies."
  exit 1
fi
