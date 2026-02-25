#!/usr/bin/env bash
# init.sh - Interactive project configuration wizard
# Generates hatch.conf with smart auto-detection

# Source detection library
source "$HATCH_HOME/lib/detect.sh"

# ---------------------------------------------------------------------------
# Mode Detection
# ---------------------------------------------------------------------------

_INIT_AUTO=false
if [[ "${1:-}" == "--auto" ]] || [[ ! -t 0 ]]; then
  _INIT_AUTO=true
fi

# ---------------------------------------------------------------------------
# Prompt Helpers
# ---------------------------------------------------------------------------

# _prompt_value PROMPT DEFAULT
# Prompts for a single-line value. Returns default on empty input.
# In auto mode, always returns default without prompting.
# Result stored in _PROMPT_RESULT
_prompt_value() {
  local prompt="$1"
  local default="$2"

  if $_INIT_AUTO; then
    _PROMPT_RESULT="$default"
    return
  fi

  local input
  read -r -p "  ${prompt} [${default}]: " input
  _PROMPT_RESULT="${input:-$default}"
}

# _prompt_multiline LABEL VALUE
# Shows a multi-line value and offers accept/edit/skip.
# In auto mode, always accepts the detected value.
# Result stored in _PROMPT_RESULT ("" if skipped)
_prompt_multiline() {
  local label="$1"
  local value="$2"

  if $_INIT_AUTO; then
    _PROMPT_RESULT="$value"
    return
  fi

  if [[ -z "$value" ]]; then
    _PROMPT_RESULT=""
    return
  fi

  # Display detected values with numbering
  echo ""
  echo "  Detected:"
  local num=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "    ${num}. ${line}"
    num=$((num + 1))
  done <<< "$value"
  echo ""

  local choice
  read -r -p "  [Enter] accept  [e] edit  [s] skip: " choice

  case "$choice" in
    e|E)
      echo "  Enter values (one per line, empty line to finish):"
      local new_value=""
      while true; do
        local line
        read -r -p "  > " line
        [[ -z "$line" ]] && break
        if [[ -n "$new_value" ]]; then
          new_value="${new_value}"$'\n'"${line}"
        else
          new_value="$line"
        fi
      done
      _PROMPT_RESULT="$new_value"
      ;;
    s|S)
      _PROMPT_RESULT=""
      ;;
    *)
      _PROMPT_RESULT="$value"
      ;;
  esac
}

# _prompt_confirm MESSAGE DEFAULT
# Asks a y/n question. Returns 0 for yes, 1 for no.
# In auto mode, returns the default.
_prompt_confirm() {
  local message="$1"
  local default="${2:-y}"

  if $_INIT_AUTO; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi

  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"

  local answer
  read -r -p "  ${message} ${hint}: " answer
  answer="${answer:-$default}"

  case "$answer" in
    y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# _prompt_choice PROMPT DEFAULT OPTIONS...
# Shows numbered options and returns selected value.
# Result stored in _PROMPT_RESULT
_prompt_choice() {
  local prompt="$1"
  local default="$2"
  shift 2

  if $_INIT_AUTO; then
    _PROMPT_RESULT="$default"
    return
  fi

  local num=1
  for opt in "$@"; do
    local marker="  "
    [[ "$opt" == "$default" ]] && marker="> "
    echo "  ${marker}${num}) ${opt}"
    num=$((num + 1))
  done
  echo ""

  local choice
  read -r -p "  ${prompt} [1]: " choice
  choice="${choice:-1}"

  # Get the selected option by number
  num=1
  for opt in "$@"; do
    if [[ "$num" == "$choice" ]]; then
      _PROMPT_RESULT="$opt"
      return
    fi
    num=$((num + 1))
  done

  # Invalid choice, use default
  _PROMPT_RESULT="$default"
}

# _format_multiline VALUE
# Formats a newline-separated value for hatch.conf output
# Adds 2-space indent to each line
_format_multiline() {
  local value="$1"
  [[ -z "$value" ]] && return 0

  while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    echo "  $line"
  done <<< "$value"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------

_header "Hatch Init"
echo ""

if $_INIT_AUTO; then
  _info "Running in auto mode (using detected defaults)"
  echo ""
fi

# Check for existing config
_EXISTING_CONFIG=""
if [[ -f ".hatch/hatch.conf" ]]; then
  _EXISTING_CONFIG=".hatch/hatch.conf"
elif [[ -f "hatch.conf" ]]; then
  _EXISTING_CONFIG="hatch.conf"
fi

if [[ -n "$_EXISTING_CONFIG" ]] && ! $_INIT_AUTO; then
  _warn "Found existing config: $_EXISTING_CONFIG"
  if ! _prompt_confirm "Overwrite it?"; then
    _info "Aborted"
    exit 0
  fi
  echo ""
fi

# ---- Section 1: Project Name ----
_header "Project"

_DETECTED_PROJECT=$(_detect_project_name)
_prompt_value "Project name" "$_DETECTED_PROJECT"
_CFG_PROJECT_NAME="$_PROMPT_RESULT"
_success "$_CFG_PROJECT_NAME"

# ---- Section 2: Package Manager ----
_DETECTED_PKG=$(_detect_package_manager)
_prompt_value "Package manager" "$_DETECTED_PKG"
_CFG_PACKAGE_MANAGER="$_PROMPT_RESULT"
_success "$_CFG_PACKAGE_MANAGER"
echo ""

# ---- Section 3: Docker Services ----
_COMPOSE_FILE=$(_detect_docker_compose_file)
_CFG_DOCKER_SERVICES=""
_CFG_DOCKER_EXTRAS=""
_CFG_DOCKER_ENV=""
_HAS_DOCKER="no"

if [[ -n "$_COMPOSE_FILE" ]]; then
  _HAS_DOCKER="yes"
  _info "Found $_COMPOSE_FILE"

  # Parse services and classify them
  _INIT_INFRA=""
  _INIT_EXTRAS=""
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    _INIT_SVC_NAME="${service_spec%%:*}"
    _INIT_SVC_CLASS=$(_classify_docker_service "$_INIT_SVC_NAME")
    if [[ "$_INIT_SVC_CLASS" == "extra" ]]; then
      if [[ -n "$_INIT_EXTRAS" ]]; then
        _INIT_EXTRAS="${_INIT_EXTRAS}"$'\n'"${service_spec}"
      else
        _INIT_EXTRAS="$service_spec"
      fi
    else
      if [[ -n "$_INIT_INFRA" ]]; then
        _INIT_INFRA="${_INIT_INFRA}"$'\n'"${service_spec}"
      else
        _INIT_INFRA="$service_spec"
      fi
    fi
  done < <(_parse_docker_services "$_COMPOSE_FILE")

  # Docker services (infrastructure)
  if [[ -n "$_INIT_INFRA" ]]; then
    _header "Docker Services"
    _prompt_multiline "Docker services" "$_INIT_INFRA"
    _CFG_DOCKER_SERVICES="$_PROMPT_RESULT"
    if [[ -n "$_CFG_DOCKER_SERVICES" ]]; then
      _success "$(echo "$_CFG_DOCKER_SERVICES" | wc -l | tr -d ' ') service(s) configured"
    fi
  fi

  # Docker extras (dev tools)
  if [[ -n "$_INIT_EXTRAS" ]]; then
    _header "Docker Extras"
    _prompt_multiline "Docker extras (dev tools)" "$_INIT_EXTRAS"
    _CFG_DOCKER_EXTRAS="$_PROMPT_RESULT"
    if [[ -n "$_CFG_DOCKER_EXTRAS" ]]; then
      _success "$(echo "$_CFG_DOCKER_EXTRAS" | wc -l | tr -d ' ') extra(s) configured"
    fi
  fi

  echo ""
fi

# ---- Section 4: Dev Servers ----
_header "Dev Servers"

_DETECTED_SERVERS=$(_detect_dev_servers "$_CFG_PACKAGE_MANAGER")
if [[ -n "$_DETECTED_SERVERS" ]]; then
  _prompt_multiline "Dev servers" "$_DETECTED_SERVERS"
  _CFG_DEV_SERVERS="$_PROMPT_RESULT"
else
  _CFG_DEV_SERVERS=""
  if ! $_INIT_AUTO; then
    _info "No dev servers auto-detected"
    if _prompt_confirm "Add dev servers manually?" "n"; then
      echo "  Format: name:directory:command:port_offset"
      echo "  Example: web:apps/web:vite --port {PORT} --host 0.0.0.0:10"
      _INIT_NEW_SERVERS=""
      while true; do
        _INIT_LINE=""
        read -r -p "  > " _INIT_LINE
        [[ -z "$_INIT_LINE" ]] && break
        if [[ -n "$_INIT_NEW_SERVERS" ]]; then
          _INIT_NEW_SERVERS="${_INIT_NEW_SERVERS}"$'\n'"${_INIT_LINE}"
        else
          _INIT_NEW_SERVERS="$_INIT_LINE"
        fi
      done
      _CFG_DEV_SERVERS="$_INIT_NEW_SERVERS"
    fi
  fi
fi

if [[ -n "$_CFG_DEV_SERVERS" ]]; then
  _success "$(echo "$_CFG_DEV_SERVERS" | wc -l | tr -d ' ') server(s) configured"
fi
echo ""

# ---- Section 5: Migration Tool ----
_header "Migrations"

_DETECTED_MIGRATE=$(_detect_migrate_tool)
_prompt_value "Migration tool" "$_DETECTED_MIGRATE"
_CFG_MIGRATE_TOOL="$_PROMPT_RESULT"
_CFG_MIGRATIONS_DIR=""
_CFG_MIGRATIONS_EXT=""

if [[ "$_CFG_MIGRATE_TOOL" != "none" ]]; then
  _success "$_CFG_MIGRATE_TOOL"
  _CFG_MIGRATIONS_DIR=$(_detect_migrations_dir "$_CFG_MIGRATE_TOOL")
  _CFG_MIGRATIONS_EXT=$(_detect_migrations_ext "$_CFG_MIGRATE_TOOL")
fi

# ---- Section 6: Database Credentials ----
_CFG_DB_USER=""
_CFG_DB_PASS=""
_CFG_DB_NAME=""

if [[ -n "$_COMPOSE_FILE" ]]; then
  _detect_db_credentials "$_COMPOSE_FILE"

  if [[ -n "$_DETECTED_DB_USER" ]]; then
    if ! $_INIT_AUTO; then
      echo ""
      _info "Detected DB credentials: user=$_DETECTED_DB_USER pass=$_DETECTED_DB_PASS db=$_DETECTED_DB_NAME"
    fi
    _prompt_value "DB user" "$_DETECTED_DB_USER"
    _CFG_DB_USER="$_PROMPT_RESULT"
    _prompt_value "DB password" "$_DETECTED_DB_PASS"
    _CFG_DB_PASS="$_PROMPT_RESULT"
    _prompt_value "DB name" "$_DETECTED_DB_NAME"
    _CFG_DB_NAME="$_PROMPT_RESULT"
  fi
fi
echo ""

# ---- Section 7: MCP Servers ----
_CFG_MCP_SERVERS=""
_CFG_MCP_ENV=""

_DETECTED_MCP=$(_detect_mcp_servers "$_CFG_PROJECT_NAME")
if [[ -n "$_DETECTED_MCP" ]]; then
  _header "MCP Servers"
  _prompt_multiline "MCP servers" "$_DETECTED_MCP"
  _CFG_MCP_SERVERS="$_PROMPT_RESULT"
  if [[ -n "$_CFG_MCP_SERVERS" ]]; then
    _success "MCP configured"
  fi
  echo ""
fi

# ---- Section 8: Setup Steps ----
_header "Setup Steps"

_HAS_DEPS="no"
[[ "$_CFG_PACKAGE_MANAGER" != "none" ]] && _HAS_DEPS="yes"

_DETECTED_STEPS=$(_infer_setup_steps "$_HAS_DOCKER" "$_HAS_DEPS" "$_CFG_MIGRATE_TOOL")
_prompt_value "Setup steps" "$_DETECTED_STEPS"
_CFG_SETUP_STEPS="$_PROMPT_RESULT"
_success "$_CFG_SETUP_STEPS"

# ---- Section 9: Post-Install Command ----
_CFG_POST_INSTALL=""
_DETECTED_POST=$(_detect_post_install_cmd)
if [[ -n "$_DETECTED_POST" ]]; then
  _prompt_value "Post-install command" "$_DETECTED_POST"
  _CFG_POST_INSTALL="$_PROMPT_RESULT"
fi

# ---- Section 10: Hooks File ----
_CFG_HOOKS_FILE="hatch.hooks.sh"
_DETECTED_HOOKS=$(_detect_hooks_file)
if [[ -n "$_DETECTED_HOOKS" ]]; then
  _prompt_value "Hooks file" "$_DETECTED_HOOKS"
  _CFG_HOOKS_FILE="$_PROMPT_RESULT"
fi
echo ""

# ---- Section 11: Save Location ----
_header "Save Location"

_prompt_choice "Where to save?" ".hatch/hatch.conf" \
  ".hatch/hatch.conf" \
  "hatch.conf" \
  "${HATCH_PROJECTS}/${_CFG_PROJECT_NAME}.conf"
_CFG_SAVE_PATH="$_PROMPT_RESULT"

# Create parent directory if needed
mkdir -p "$(dirname "$_CFG_SAVE_PATH")"

echo ""

# ---------------------------------------------------------------------------
# Generate Config
# ---------------------------------------------------------------------------

_header "Generating Config"

{
  echo "# ${_CFG_PROJECT_NAME} - hatch configuration"
  echo ""
  echo "PROJECT_NAME=\"${_CFG_PROJECT_NAME}\""
  echo "PACKAGE_MANAGER=\"${_CFG_PACKAGE_MANAGER}\""

  # Docker services
  if [[ -n "$_CFG_DOCKER_SERVICES" ]]; then
    echo ""
    echo "# Docker services from docker-compose.yaml"
    echo "DOCKER_SERVICES=\""
    _format_multiline "$_CFG_DOCKER_SERVICES"
    echo "\""
  fi

  # Docker extras
  if [[ -n "$_CFG_DOCKER_EXTRAS" ]]; then
    echo ""
    echo "DOCKER_EXTRAS=\""
    _format_multiline "$_CFG_DOCKER_EXTRAS"
    echo "\""
  fi

  # Docker env
  if [[ -n "$_CFG_DOCKER_ENV" ]]; then
    echo ""
    echo "# Docker service environment overrides"
    echo "DOCKER_ENV=\""
    _format_multiline "$_CFG_DOCKER_ENV"
    echo "\""
  fi

  # Dev servers
  if [[ -n "$_CFG_DEV_SERVERS" ]]; then
    echo ""
    echo "# Dev servers"
    echo "DEV_SERVERS=\""
    _format_multiline "$_CFG_DEV_SERVERS"
    echo "\""
  fi

  # Port templates (empty section — filled by AI skill)
  # Only write a commented hint if there are docker services or dev servers
  if [[ -n "$_CFG_DOCKER_SERVICES" ]] || [[ -n "$_CFG_DEV_SERVERS" ]]; then
    echo ""
    echo "# Dynamic port injection into config files"
    echo "# Format: \"file_path:VAR_NAME=value_with_{PORT_servicename}_placeholder\""
    echo "# Tip: use your AI coding assistant with ~/.hatch/prompts/hatch-init.md to auto-configure"
    echo "PORT_TEMPLATES=\""
    echo "\""
  fi

  # MCP servers
  if [[ -n "$_CFG_MCP_SERVERS" ]]; then
    echo ""
    echo "# MCP servers"
    echo "MCP_SERVERS=\""
    _format_multiline "$_CFG_MCP_SERVERS"
    echo "\""
  fi

  # MCP env (empty section — filled by AI skill)
  if [[ -n "$_CFG_MCP_SERVERS" ]]; then
    echo ""
    echo "# MCP environment variables (supports {PORT_servicename} placeholders)"
    echo "# Tip: use your AI coding assistant with ~/.hatch/prompts/hatch-init.md to auto-configure"
    echo "MCP_ENV=\""
    echo "\""
  fi

  # Migrations
  if [[ "$_CFG_MIGRATE_TOOL" != "none" ]]; then
    echo ""
    echo "# Migrations"
    echo "MIGRATE_TOOL=\"${_CFG_MIGRATE_TOOL}\""
    [[ -n "$_CFG_MIGRATIONS_DIR" ]] && echo "MIGRATIONS_DIR=\"${_CFG_MIGRATIONS_DIR}\""
    [[ -n "$_CFG_MIGRATIONS_EXT" ]] && echo "MIGRATIONS_FILE_EXT=\"${_CFG_MIGRATIONS_EXT}\""
  fi

  # Database
  if [[ -n "$_CFG_DB_USER" ]]; then
    echo ""
    echo "# Database"
    echo "DB_USER=\"${_CFG_DB_USER}\""
    echo "DB_PASSWORD=\"${_CFG_DB_PASS}\""
    echo "DB_NAME=\"${_CFG_DB_NAME}\""
  fi

  # Setup steps
  echo ""
  echo "# Setup steps"
  echo "SETUP_STEPS=\"${_CFG_SETUP_STEPS}\""

  # Post-install
  if [[ -n "$_CFG_POST_INSTALL" ]]; then
    echo ""
    echo "# Post-install command"
    echo "POST_INSTALL_CMD=\"${_CFG_POST_INSTALL}\""
  fi

  # Hooks
  echo ""
  echo "# Hooks"
  echo "HOOKS_FILE=\"${_CFG_HOOKS_FILE}\""

} > "$_CFG_SAVE_PATH"

echo ""
_success "Created $_CFG_SAVE_PATH"
echo ""

# Summary
echo "Next steps:"
if [[ -n "$_CFG_DOCKER_SERVICES" ]] || [[ -n "$_CFG_MCP_SERVERS" ]]; then
  echo "  1. Use your AI assistant with ~/.hatch/prompts/hatch-init.md to configure PORT_TEMPLATES, SECRETS, and MCP_ENV"
  echo "  2. Run: hatch setup"
else
  echo "  1. Review $_CFG_SAVE_PATH and add any missing configuration"
  echo "  2. Run: hatch setup"
fi
