#!/usr/bin/env bash
# status.sh - Show Docker and dev server status
# Sources: manifest, ports, docker, process

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"
source "$HATCH_LIB/docker.sh"
source "$HATCH_LIB/process.sh"

# Parse flags
MD_OUTPUT=0
for arg in "$@"; do
  case "$arg" in
    --md) MD_OUTPUT=1 ;;
  esac
done

# Load manifest and allocate ports
# In --md mode, redirect setup noise to stderr so only clean markdown hits stdout
if [[ $MD_OUTPUT -eq 1 ]]; then
  PROJECT_NAME=$(hatch_detect_project)
  WORKSPACE_NAME=$(hatch_resolve_workspace)
  hatch_load_manifest "$PROJECT_NAME" >&2
  hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME" >&2
  hatch_allocate_ports >&2
else
  PROJECT_NAME=$(hatch_detect_project)
  WORKSPACE_NAME=$(hatch_resolve_workspace)
  hatch_load_manifest "$PROJECT_NAME"
  hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
  hatch_allocate_ports
fi

if [[ $MD_OUTPUT -eq 1 ]]; then
  # ---------------------------------------------------------------
  # Markdown mode — plain text, no ANSI colors, no [info] prefixes
  # ---------------------------------------------------------------

  echo "# $PROJECT_NAME"
  echo ""
  echo "Workspace: \`$WORKSPACE_NAME\`  "
  echo "Base port: \`$BASE_PORT\`"
  echo ""

  # -- Docker Services table --
  has_docker=0
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    has_docker=1
    break
  done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS)

  if [[ $has_docker -eq 1 ]]; then
    echo "## Docker Services"
    echo ""
    echo "| Service | Port | URL | Status |"
    echo "|---------|------|-----|--------|"

    while IFS= read -r service_spec; do
      [[ -z "$service_spec" ]] && continue
      name=$(echo "$service_spec" | cut -d: -f1)
      port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
      if [[ -n "$port" ]]; then
        url="http://localhost:$port"
        if _check_port "$port"; then
          status="running"
        else
          status="stopped"
        fi
        echo "| $name | $port | $url | $status |"
      else
        echo "| $name | n/a | n/a | unknown |"
      fi
    done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS)
    echo ""
  fi

  # -- Dev Servers table --
  has_servers=0
  while IFS= read -r server_spec; do
    [[ -z "$server_spec" ]] && continue
    has_servers=1
    break
  done < <(_parse_services DEV_SERVERS)

  if [[ $has_servers -eq 1 ]]; then
    echo "## Dev Servers"
    echo ""
    echo "| Name | Port | URL | Status |"
    echo "|------|------|-----|--------|"

    while IFS= read -r server_spec; do
      [[ -z "$server_spec" ]] && continue
      name=$(echo "$server_spec" | cut -d: -f1)
      port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
      if [[ -n "$port" ]]; then
        url="http://localhost:$port"
        status="stopped"
        if [[ -f .hatch/pids ]]; then
          while IFS=: read -r pname ppid pport pdir; do
            if [[ "$pname" == "$name" ]] && kill -0 "$ppid" 2>/dev/null; then
              status="running"
              break
            fi
          done < .hatch/pids
        fi
        echo "| $name | $port | $url | $status |"
      else
        echo "| $name | n/a | n/a | unknown |"
      fi
    done < <(_parse_services DEV_SERVERS)
    echo ""
  fi

  # -- Database section (dev-only credentials, safe to display) --
  if [[ -n "${DB_USER:-}" ]] || [[ -n "${DB_NAME:-}" ]]; then
    db_password="${DB_PASSWORD:-${DB_PASS:-}}"
    db_host="localhost"
    db_scheme="postgresql"
    db_port=$(hatch_resolve_port "postgres" 2>/dev/null || echo "")
    if [[ -z "$db_port" ]]; then
      db_port=$(hatch_resolve_port "mysql" 2>/dev/null || echo "")
      [[ -n "$db_port" ]] && db_scheme="mysql"
    fi
    db_port="${db_port:-5432}"

    echo "## Database"
    echo ""
    echo "- **Host:** $db_host"
    echo "- **Port:** $db_port"
    echo "- **User:** ${DB_USER:-}"
    echo "- **Password:** ${db_password}"
    echo "- **Database:** ${DB_NAME:-}"
    echo "- **Connection string:** \`${db_scheme}://${DB_USER:-}:${db_password}@${db_host}:${db_port}/${DB_NAME:-}\`"
    echo ""
  fi

  # -- MCP Servers table --
  if [[ -n "${MCP_SERVERS:-}" ]]; then
    echo "## MCP Servers"
    echo ""
    echo "| Name | Command |"
    echo "|------|---------|"

    while IFS= read -r server_spec; do
      [[ -z "$server_spec" ]] && continue
      name=$(echo "$server_spec" | cut -d: -f1)
      mcp_cmd=$(echo "$server_spec" | cut -d: -f2-)
      echo "| $name | \`$mcp_cmd\` |"
    done < <(_parse_services MCP_SERVERS)
    echo ""
  fi

  # -- URLs section --
  has_urls=0
  url_lines=""
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    name=$(echo "$service_spec" | cut -d: -f1)
    port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
    if [[ -n "$port" ]]; then
      has_urls=1
      url_lines="${url_lines}- **$name:** http://localhost:$port
"
    fi
  done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS; _parse_services DEV_SERVERS)

  if [[ $has_urls -eq 1 ]]; then
    echo "## URLs"
    echo ""
    printf '%s' "$url_lines"
  fi

else
  # ---------------------------------------------------------------
  # Normal mode — colored terminal output
  # ---------------------------------------------------------------

  _header "$PROJECT_NAME Status"
  echo ""

  # Docker services
  _info "Docker Services:"
  hatch_docker_status
  echo ""

  # Dev servers
  _info "Dev Servers:"
  hatch_server_status
  echo ""

  # Database (dev-only credentials, safe to display)
  if [[ -n "${DB_USER:-}" ]] || [[ -n "${DB_NAME:-}" ]]; then
    db_password="${DB_PASSWORD:-${DB_PASS:-}}"
    db_host="localhost"
    db_scheme="postgresql"
    db_port=$(hatch_resolve_port "postgres" 2>/dev/null || echo "")
    if [[ -z "$db_port" ]]; then
      db_port=$(hatch_resolve_port "mysql" 2>/dev/null || echo "")
      [[ -n "$db_port" ]] && db_scheme="mysql"
    fi
    db_port="${db_port:-5432}"

    _info "Database:"
    echo "  Host:              $db_host"
    echo "  Port:              $db_port"
    echo "  User:              ${DB_USER:-}"
    echo "  Password:          ${db_password}"
    echo "  Database:          ${DB_NAME:-}"
    echo "  Connection string: ${db_scheme}://${DB_USER:-}:${db_password}@${db_host}:${db_port}/${DB_NAME:-}"
    echo ""
  fi

  # MCP Servers
  if [[ -n "${MCP_SERVERS:-}" ]]; then
    _info "MCP Servers:"
    while IFS= read -r server_spec; do
      [[ -z "$server_spec" ]] && continue
      name=$(echo "$server_spec" | cut -d: -f1)
      mcp_cmd=$(echo "$server_spec" | cut -d: -f2-)
      echo "  $name: $mcp_cmd"
    done < <(_parse_services MCP_SERVERS)
    echo ""
  fi

  # URLs
  _info "Available URLs:"
  while IFS= read -r service_spec; do
    [[ -z "$service_spec" ]] && continue
    name=$(echo "$service_spec" | cut -d: -f1)
    port=$(hatch_resolve_port "$name" 2>/dev/null || echo "")
    if [[ -n "$port" ]]; then
      echo "  $name: http://localhost:$port"
    fi
  done < <(_parse_services DOCKER_SERVICES; _parse_services DOCKER_EXTRAS; _parse_services DEV_SERVERS)
fi
