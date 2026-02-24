#!/usr/bin/env bash
# detect.sh - Project auto-detection for hatch init
# Depends on: core.sh

# ---------------------------------------------------------------------------
# Project Identity Detection
# ---------------------------------------------------------------------------

# _detect_project_name
# Detects project name from: git remote > directory name
# Outputs: project name string
_detect_project_name() {
  if git remote get-url origin >/dev/null 2>&1; then
    local remote_url
    remote_url=$(git remote get-url origin)
    basename "$remote_url" .git
    return
  fi
  basename "$PWD"
}

# _detect_package_manager
# Detects package manager from lock files
# Outputs: "bun"|"pnpm"|"yarn"|"npm"|"none"
_detect_package_manager() {
  if [[ -f "bun.lockb" ]] || [[ -f "bun.lock" ]]; then
    echo "bun"
  elif [[ -f "pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "yarn.lock" ]]; then
    echo "yarn"
  elif [[ -f "package-lock.json" ]]; then
    echo "npm"
  else
    echo "none"
  fi
}

# ---------------------------------------------------------------------------
# Lightweight JSON Helpers (no jq dependency)
# ---------------------------------------------------------------------------

# _json_string_field FILE FIELD
# Reads a simple string field from a JSON file
# Handles: "field": "value"
# Outputs: the unquoted value, or "" if not found
_json_string_field() {
  local file="$1"
  local field="$2"
  grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null \
    | head -1 \
    | sed 's/.*:[[:space:]]*"//;s/"$//' \
    || true
}

# _json_array_field FILE FIELD
# Reads a simple JSON array of strings from a file
# Handles: "field": ["a", "b", "c"] (single-line or multi-line)
# Outputs: one value per line (unquoted)
_json_array_field() {
  local file="$1"
  local field="$2"

  # Extract the array content between [ and ]
  # Use awk to handle multi-line arrays
  awk -v field="\"${field}\"" '
    $0 ~ field {
      found = 1
      sub(/.*\[/, "[")
    }
    found {
      buf = buf $0
      if (index(buf, "]")) {
        # Extract content between [ and ]
        sub(/.*\[/, "", buf)
        sub(/\].*/, "", buf)
        # Split by comma and print each quoted string
        n = split(buf, parts, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[[:space:]]*"/, "", parts[i])
          gsub(/"[[:space:]]*$/, "", parts[i])
          if (parts[i] != "") print parts[i]
        }
        exit
      }
    }
  ' "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Docker Compose Parsing
# ---------------------------------------------------------------------------

# _detect_docker_compose_file
# Finds docker-compose file in current directory
# Outputs: filename or "" if not found
_detect_docker_compose_file() {
  if [[ -f "docker-compose.yaml" ]]; then
    echo "docker-compose.yaml"
  elif [[ -f "docker-compose.yml" ]]; then
    echo "docker-compose.yml"
  fi
}

# _parse_docker_services COMPOSE_FILE
# Parses docker-compose.yaml to extract service names and container ports
# Outputs: newline-separated "service_name:container_port[,port2]" entries
# Uses a line-by-line state machine to parse YAML structure
_parse_docker_services() {
  local compose_file="$1"
  [[ -f "$compose_file" ]] || return 0

  local state="idle"
  local current_service=""
  local current_ports=""

  while IFS= read -r line; do
    # Calculate indentation (number of leading spaces)
    local stripped="${line#"${line%%[![:space:]]*}"}"
    local spaces=$(( ${#line} - ${#stripped} ))

    # Skip empty lines and comments
    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    case "$state" in
      idle)
        if [[ "$stripped" == "services:" ]]; then
          state="in_services"
        fi
        ;;
      in_services)
        # A service name is at 2-space indent with trailing colon (no value)
        if [[ $spaces -eq 2 ]] && [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
          # Emit previous service if it had ports
          if [[ -n "$current_service" ]] && [[ -n "$current_ports" ]]; then
            echo "${current_service}:${current_ports}"
          fi
          current_service="${BASH_REMATCH[1]}"
          current_ports=""
          state="in_service"
        elif [[ $spaces -eq 0 ]] && [[ -n "$stripped" ]]; then
          # Left top-level services block
          break
        fi
        ;;
      in_service)
        if [[ $spaces -le 2 ]]; then
          # Back to service level or new top-level block
          if [[ -n "$current_service" ]] && [[ -n "$current_ports" ]]; then
            echo "${current_service}:${current_ports}"
          fi
          if [[ $spaces -eq 2 ]] && [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
            current_service="${BASH_REMATCH[1]}"
            current_ports=""
          elif [[ $spaces -eq 0 ]]; then
            current_service=""
            current_ports=""
            state="idle"
            break
          fi
        elif [[ $spaces -eq 4 ]] && [[ "$stripped" == "ports:" ]]; then
          state="in_ports"
        fi
        ;;
      in_ports)
        if [[ $spaces -ge 6 ]] && [[ "$stripped" =~ ^-[[:space:]] ]]; then
          # Parse port entry: strip list marker, quotes, protocol suffix
          local port_val="${stripped#- }"
          port_val="${port_val//\"/}"
          port_val="${port_val//\'/}"
          # Strip variable references like ${PORT_X}:CONTAINER or $PORT:CONTAINER
          # We only want the container port (rightmost number)

          # Strip /tcp, /udp suffix
          port_val="${port_val%%/*}"

          local container_port
          if [[ "$port_val" == *":"* ]]; then
            # HOST:CONTAINER or HOST:CONTAINER format
            container_port="${port_val##*:}"
          else
            container_port="$port_val"
          fi

          # Only add if it's a number
          if [[ "$container_port" =~ ^[0-9]+$ ]]; then
            if [[ -n "$current_ports" ]]; then
              current_ports="${current_ports},${container_port}"
            else
              current_ports="$container_port"
            fi
          fi
        elif [[ $spaces -le 4 ]]; then
          # Exited ports section
          state="in_service"
          # Re-evaluate this line in service context
          if [[ $spaces -le 2 ]]; then
            if [[ -n "$current_service" ]] && [[ -n "$current_ports" ]]; then
              echo "${current_service}:${current_ports}"
            fi
            if [[ $spaces -eq 2 ]] && [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
              current_service="${BASH_REMATCH[1]}"
              current_ports=""
            elif [[ $spaces -eq 0 ]]; then
              current_service=""
              current_ports=""
              state="idle"
              break
            fi
          fi
        fi
        ;;
    esac
  done < "$compose_file"

  # Emit last service
  if [[ -n "$current_service" ]] && [[ -n "$current_ports" ]]; then
    echo "${current_service}:${current_ports}"
  fi
}

# _classify_docker_service NAME
# Returns: "infra" for infrastructure services, "extra" for dev tools
_classify_docker_service() {
  local name="$1"
  case "$name" in
    # Dev tools / web UIs
    adminer|phpmyadmin|pgadmin*|mailhog|mailpit|redis-commander|mongo-express|kibana|gotenberg|unoserver)
      echo "extra"
      ;;
    # Everything else is infrastructure
    *)
      echo "infra"
      ;;
  esac
}

# _parse_docker_env COMPOSE_FILE SERVICE_NAME
# Extracts environment variables from a service's environment: section
# Outputs: newline-separated "KEY=value" entries
_parse_docker_env() {
  local compose_file="$1"
  local target_service="$2"
  [[ -f "$compose_file" ]] || return 0

  local state="idle"
  local current_service=""

  while IFS= read -r line; do
    local stripped="${line#"${line%%[![:space:]]*}"}"
    local spaces=$(( ${#line} - ${#stripped} ))

    [[ -z "$stripped" ]] && continue
    [[ "$stripped" == \#* ]] && continue

    case "$state" in
      idle)
        [[ "$stripped" == "services:" ]] && state="in_services"
        ;;
      in_services)
        if [[ $spaces -eq 2 ]] && [[ "$stripped" =~ ^([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
          current_service="${BASH_REMATCH[1]}"
          if [[ "$current_service" == "$target_service" ]]; then
            state="in_target_service"
          fi
        elif [[ $spaces -eq 0 ]] && [[ -n "$stripped" ]]; then
          break
        fi
        ;;
      in_target_service)
        if [[ $spaces -le 2 ]]; then
          break
        elif [[ $spaces -eq 4 ]] && [[ "$stripped" == "environment:" ]]; then
          state="in_env"
        fi
        ;;
      in_env)
        if [[ $spaces -le 4 ]]; then
          break
        fi
        if [[ "$stripped" =~ ^-[[:space:]] ]]; then
          # List format: - KEY=value
          local entry="${stripped#- }"
          entry="${entry//\"/}"
          entry="${entry//\'/}"
          echo "$entry"
        elif [[ "$stripped" =~ ^([A-Z_][A-Z0-9_]*):[[:space:]]*(.*) ]]; then
          # Map format: KEY: value
          local key="${BASH_REMATCH[1]}"
          local val="${BASH_REMATCH[2]}"
          val="${val//\"/}"
          val="${val//\'/}"
          echo "${key}=${val}"
        fi
        ;;
    esac
  done < "$compose_file"
}

# _detect_db_credentials COMPOSE_FILE
# Extracts database credentials from docker-compose environment
# Sets globals: _DETECTED_DB_USER, _DETECTED_DB_PASS, _DETECTED_DB_NAME
_detect_db_credentials() {
  local compose_file="$1"
  _DETECTED_DB_USER=""
  _DETECTED_DB_PASS=""
  _DETECTED_DB_NAME=""

  [[ -f "$compose_file" ]] || return 0

  # Try postgres service first
  local env_lines
  env_lines=$(_parse_docker_env "$compose_file" "postgres")
  if [[ -n "$env_lines" ]]; then
    while IFS= read -r line; do
      case "$line" in
        POSTGRES_USER=*) _DETECTED_DB_USER="${line#POSTGRES_USER=}" ;;
        POSTGRES_PASSWORD=*) _DETECTED_DB_PASS="${line#POSTGRES_PASSWORD=}" ;;
        POSTGRES_DB=*) _DETECTED_DB_NAME="${line#POSTGRES_DB=}" ;;
      esac
    done <<< "$env_lines"
    # Defaults for postgres
    [[ -z "$_DETECTED_DB_USER" ]] && _DETECTED_DB_USER="postgres"
    [[ -z "$_DETECTED_DB_PASS" ]] && _DETECTED_DB_PASS="postgres"
    [[ -z "$_DETECTED_DB_NAME" ]] && _DETECTED_DB_NAME="postgres"
    return 0
  fi

  # Try contember-engine (uses contember defaults)
  env_lines=$(_parse_docker_env "$compose_file" "contember-engine")
  if [[ -n "$env_lines" ]]; then
    while IFS= read -r line; do
      case "$line" in
        CONTEMBER_POSTGRES_USER=*) _DETECTED_DB_USER="${line#CONTEMBER_POSTGRES_USER=}" ;;
        CONTEMBER_POSTGRES_PASSWORD=*) _DETECTED_DB_PASS="${line#CONTEMBER_POSTGRES_PASSWORD=}" ;;
        CONTEMBER_POSTGRES_DB=*) _DETECTED_DB_NAME="${line#CONTEMBER_POSTGRES_DB=}" ;;
      esac
    done <<< "$env_lines"
    # Contember defaults
    [[ -z "$_DETECTED_DB_USER" ]] && _DETECTED_DB_USER="contember"
    [[ -z "$_DETECTED_DB_PASS" ]] && _DETECTED_DB_PASS="contember"
    [[ -z "$_DETECTED_DB_NAME" ]] && _DETECTED_DB_NAME="contember"
    return 0
  fi

  # Try mysql service
  env_lines=$(_parse_docker_env "$compose_file" "mysql")
  if [[ -n "$env_lines" ]]; then
    while IFS= read -r line; do
      case "$line" in
        MYSQL_USER=*) _DETECTED_DB_USER="${line#MYSQL_USER=}" ;;
        MYSQL_ROOT_PASSWORD=*) _DETECTED_DB_PASS="${line#MYSQL_ROOT_PASSWORD=}" ;;
        MYSQL_PASSWORD=*) _DETECTED_DB_PASS="${line#MYSQL_PASSWORD=}" ;;
        MYSQL_DATABASE=*) _DETECTED_DB_NAME="${line#MYSQL_DATABASE=}" ;;
      esac
    done <<< "$env_lines"
    [[ -z "$_DETECTED_DB_USER" ]] && _DETECTED_DB_USER="root"
    [[ -z "$_DETECTED_DB_PASS" ]] && _DETECTED_DB_PASS="root"
    [[ -z "$_DETECTED_DB_NAME" ]] && _DETECTED_DB_NAME="mysql"
    return 0
  fi
}

# ---------------------------------------------------------------------------
# Monorepo + Workspace Detection
# ---------------------------------------------------------------------------

# _detect_monorepo
# Returns 0 if project is a monorepo, 1 if not
_detect_monorepo() {
  [[ -f "package.json" ]] || return 1

  # Check for yarn/npm workspaces
  if grep -q '"workspaces"' package.json 2>/dev/null; then
    return 0
  fi

  # Check for pnpm workspaces
  if [[ -f "pnpm-workspace.yaml" ]]; then
    return 0
  fi

  return 1
}

# _detect_workspace_dirs
# Resolves workspace directories from package.json or pnpm-workspace.yaml
# Outputs: newline-separated list of workspace directory paths (relative)
_detect_workspace_dirs() {
  local globs=""

  if [[ -f "pnpm-workspace.yaml" ]]; then
    # Parse pnpm workspace globs from packages: section
    globs=$(awk '/^packages:/{found=1; next} /^[^ ]/{found=0} found && /- /{gsub(/^[[:space:]]*- ["'\''"]?/, ""); gsub(/["'\''"]?[[:space:]]*$/, ""); print}' pnpm-workspace.yaml 2>/dev/null || true)
  fi

  if [[ -z "$globs" ]] && [[ -f "package.json" ]]; then
    # Read workspaces array from package.json
    globs=$(_json_array_field package.json workspaces)
  fi

  [[ -z "$globs" ]] && return 0

  # Expand each glob pattern
  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    # Remove trailing /* if present (e.g., "packages/*" -> "packages/")
    local base_pattern="${pattern%/\*}"
    # Use bash glob expansion
    # shellcheck disable=SC2086
    for dir in $base_pattern; do
      if [[ -d "$dir" ]] && [[ -f "$dir/package.json" ]]; then
        echo "$dir"
      fi
    done
  done <<< "$globs"
}

# _detect_workspace_name DIR
# Reads the "name" field from a workspace's package.json
# Outputs: package name (e.g., "@scope/admin")
_detect_workspace_name() {
  local dir="$1"
  [[ -f "$dir/package.json" ]] || return 0
  _json_string_field "$dir/package.json" "name"
}

# ---------------------------------------------------------------------------
# Dev Server Detection
# ---------------------------------------------------------------------------

# _detect_framework DIR
# Checks a directory for framework config files
# Outputs: "framework_name:suggested_command" or "" if none found
_detect_framework() {
  local dir="$1"

  # Check in order of specificity
  # shellcheck disable=SC2144
  if ls "$dir"/vite.config.* >/dev/null 2>&1; then
    echo "vite:vite --port {PORT} --strictPort --host 0.0.0.0"
    return
  fi

  if ls "$dir"/next.config.* >/dev/null 2>&1; then
    echo "next:next dev --port {PORT} --hostname 0.0.0.0"
    return
  fi

  if [[ -f "$dir/wrangler.toml" ]] || [[ -f "$dir/wrangler.jsonc" ]] || [[ -f "$dir/wrangler.json" ]]; then
    echo "wrangler:wrangler dev --port {PORT}"
    return
  fi

  if ls "$dir"/nuxt.config.* >/dev/null 2>&1; then
    echo "nuxt:nuxt dev --port {PORT}"
    return
  fi

  if ls "$dir"/remix.config.* >/dev/null 2>&1; then
    echo "remix:remix dev --port {PORT}"
    return
  fi
}

# _detect_dev_servers PKG_MANAGER
# Scans workspace directories for dev server frameworks
# Outputs: newline-separated DEV_SERVERS entries in hatch format
# "name:directory:command:port_offset"
_detect_dev_servers() {
  local pkg_manager="$1"
  local offset=10
  local project_name
  project_name=$(_detect_project_name)

  if _detect_monorepo; then
    # Monorepo: scan each workspace directory
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue

      local framework_info
      framework_info=$(_detect_framework "$dir")
      [[ -z "$framework_info" ]] && continue

      local framework_name="${framework_info%%:*}"
      local suggested_cmd="${framework_info#*:}"

      # Get directory basename for the server name
      local server_name
      server_name=$(basename "$dir")

      # Build the command based on package manager
      local command=""
      case "$pkg_manager" in
        yarn)
          local ws_name
          ws_name=$(_detect_workspace_name "$dir")
          if [[ -n "$ws_name" ]]; then
            # Check if the workspace has a "dev" script
            local dev_script
            dev_script=$(_json_string_field "$dir/package.json" "dev" || true)
            if [[ -n "$dev_script" ]] || grep -q '"dev"' "$dir/package.json" 2>/dev/null; then
              command="workspace ${ws_name} dev --port {PORT}"
              # For vite, add common flags
              if [[ "$framework_name" == "vite" ]]; then
                command="workspace ${ws_name} dev --port {PORT} --strictPort --host 0.0.0.0"
              fi
            else
              command="workspace ${ws_name} ${suggested_cmd}"
            fi
          else
            command="$suggested_cmd"
          fi
          ;;
        pnpm)
          local ws_name
          ws_name=$(_detect_workspace_name "$dir")
          if [[ -n "$ws_name" ]]; then
            command="--filter ${ws_name} dev --port {PORT}"
            if [[ "$framework_name" == "vite" ]]; then
              command="--filter ${ws_name} dev --port {PORT} --strictPort --host 0.0.0.0"
            fi
          else
            command="$suggested_cmd"
          fi
          ;;
        *)
          command="$suggested_cmd"
          ;;
      esac

      echo "${server_name}:${dir}:${command}:${offset}"
      offset=$((offset + 1))
    done < <(_detect_workspace_dirs)
  else
    # Single project: scan root directory
    local framework_info
    framework_info=$(_detect_framework ".")
    if [[ -n "$framework_info" ]]; then
      local suggested_cmd="${framework_info#*:}"
      echo "dev:.:${suggested_cmd}:${offset}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Migration Tool Detection
# ---------------------------------------------------------------------------

# _detect_migrate_tool
# Detects which migration tool the project uses
# Outputs: "prisma"|"contember"|"knex"|"drizzle"|"none"
_detect_migrate_tool() {
  if [[ -f "prisma/schema.prisma" ]]; then
    echo "prisma"
  elif [[ -d "api/migrations" ]] && grep -q "contember" package.json 2>/dev/null; then
    echo "contember"
  elif [[ -f "knexfile.js" ]] || [[ -f "knexfile.ts" ]]; then
    echo "knex"
  elif [[ -f "drizzle.config.ts" ]] || [[ -f "drizzle.config.js" ]]; then
    echo "drizzle"
  else
    echo "none"
  fi
}

# _detect_migrations_dir TOOL
# Returns the migrations directory for the detected tool
# Outputs: directory path or ""
_detect_migrations_dir() {
  local tool="$1"
  case "$tool" in
    prisma) echo "prisma/migrations" ;;
    contember) echo "api/migrations" ;;
    knex) echo "migrations" ;;
    drizzle) echo "drizzle" ;;
    *) ;;
  esac
}

# _detect_migrations_ext TOOL
# Returns the file extension for migration files
# Outputs: extension or ""
_detect_migrations_ext() {
  local tool="$1"
  case "$tool" in
    contember) echo "json" ;;
    prisma) echo "sql" ;;
    knex) echo "js" ;;
    drizzle) echo "ts" ;;
    *) ;;
  esac
}

# ---------------------------------------------------------------------------
# MCP Detection
# ---------------------------------------------------------------------------

# _detect_mcp_servers PROJECT_NAME
# Detects MCP server configuration
# Outputs: newline-separated MCP_SERVERS entries in hatch format "name:command:args"
_detect_mcp_servers() {
  local project_name="$1"

  # Check for mcp/ directory with entry point
  if [[ -d "mcp" ]]; then
    # Look for common entry points
    if [[ -f "mcp/host/src/index.ts" ]]; then
      echo "${project_name}:npx:tsx mcp/host/src/index.ts"
      return
    fi
    if [[ -f "mcp/src/index.ts" ]]; then
      echo "${project_name}:npx:tsx mcp/src/index.ts"
      return
    fi
    if [[ -f "mcp/index.ts" ]]; then
      echo "${project_name}:npx:tsx mcp/index.ts"
      return
    fi
  fi
}

# ---------------------------------------------------------------------------
# Environment File Detection
# ---------------------------------------------------------------------------

# _detect_env_files
# Finds .gitignored environment files in workspace directories
# Outputs: newline-separated file paths
_detect_env_files() {
  local files=""

  # Common env file names that are typically gitignored
  local env_names=".env.local .dev.vars .env.development"

  if _detect_monorepo; then
    while IFS= read -r dir; do
      [[ -z "$dir" ]] && continue
      for name in $env_names; do
        if [[ -f "$dir/$name" ]]; then
          echo "$dir/$name"
        fi
      done
    done < <(_detect_workspace_dirs)
  fi

  # Also check root
  for name in $env_names; do
    if [[ -f "$name" ]]; then
      echo "$name"
    fi
  done
}

# ---------------------------------------------------------------------------
# Post-Install + Hooks Detection
# ---------------------------------------------------------------------------

# _detect_post_install_cmd
# Scans package.json scripts for common post-install/codegen commands
# Outputs: command string or ""
_detect_post_install_cmd() {
  [[ -f "package.json" ]] || return 0

  local pkg_manager
  pkg_manager=$(_detect_package_manager)

  # Check for common generate/codegen scripts
  local scripts="client:generate generate build:types codegen postgenerate"
  for script in $scripts; do
    if grep -q "\"${script}\"" package.json 2>/dev/null; then
      case "$pkg_manager" in
        yarn) echo "yarn ${script}" ;;
        pnpm) echo "pnpm ${script}" ;;
        npm) echo "npm run ${script}" ;;
        bun) echo "bun run ${script}" ;;
        *) echo "${script}" ;;
      esac
      return
    fi
  done
}

# _detect_hooks_file
# Checks for existing hooks files
# Outputs: filename if found, "" otherwise
_detect_hooks_file() {
  # Check .hatch directory first
  if [[ -f ".hatch/hatch.hooks.ts" ]]; then
    echo "hatch.hooks.ts"
  elif [[ -f ".hatch/hatch.hooks.sh" ]]; then
    echo "hatch.hooks.sh"
  elif [[ -f "hatch.hooks.ts" ]]; then
    echo "hatch.hooks.ts"
  elif [[ -f "hatch.hooks.sh" ]]; then
    echo "hatch.hooks.sh"
  fi
}

# ---------------------------------------------------------------------------
# Setup Steps Inference
# ---------------------------------------------------------------------------

# _infer_setup_steps HAS_DOCKER HAS_DEPS MIGRATE_TOOL
# Builds a reasonable SETUP_STEPS string from detected features
# Outputs: space-separated step list
_infer_setup_steps() {
  local has_docker="$1"
  local has_deps="$2"
  local migrate_tool="$3"

  local steps=""

  if [[ "$has_docker" == "yes" ]]; then
    steps="docker:up"
  fi

  if [[ "$has_deps" == "yes" ]]; then
    steps="${steps:+$steps }deps:install"
  fi

  if [[ "$migrate_tool" != "none" ]]; then
    steps="${steps:+$steps }migrate:execute"
  fi

  echo "${steps:-docker:up}"
}
