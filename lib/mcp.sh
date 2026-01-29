#!/usr/bin/env bash
# mcp.sh - MCP server configuration generation
# Depends on: core.sh, manifest.sh, ports.sh
#
# MCP servers are declared in hatch.conf via MCP_SERVERS and MCP_ENV.
# hatch setup writes them into ~/.claude.json under the project path,
# keeping the project's committed .mcp.json untouched.

# hatch_generate_mcp_config
# Reads MCP_SERVERS and MCP_ENV from manifest
# Writes MCP config to ~/.claude.json (project-scoped, user-local)
# MCP_SERVERS format: "name:command:args" (one per line)
# MCP_ENV format: "server_name:KEY=value" (one per line, supports {PORT_x} placeholders)
hatch_generate_mcp_config() {
  if [[ -z "${MCP_SERVERS:-}" ]]; then
    _info "No MCP_SERVERS defined, skipping MCP configuration"
    return 0
  fi

  _header "Generating MCP configuration"

  # Build servers JSON
  local servers_json='{'
  local first_server=1

  while IFS= read -r server_spec; do
    [[ -z "$server_spec" ]] && continue

    # Parse format: "name:command:args"
    local name command args
    name=$(echo "$server_spec" | cut -d: -f1)
    command=$(echo "$server_spec" | cut -d: -f2)
    args=$(echo "$server_spec" | cut -d: -f3-)

    # Comma separator between servers
    if [[ $first_server -eq 1 ]]; then
      first_server=0
    else
      servers_json="$servers_json,"
    fi

    # Build args array
    local args_json=""
    local first_arg=1
    for arg in $args; do
      if [[ $first_arg -eq 1 ]]; then
        args_json="\"$arg\""
        first_arg=0
      else
        args_json="$args_json, \"$arg\""
      fi
    done

    # Collect env vars for this server
    local env_json=""
    local has_env=0
    if [[ -n "${MCP_ENV:-}" ]]; then
      while IFS= read -r env_spec; do
        [[ -z "$env_spec" ]] && continue

        local env_server env_assignment
        env_server=$(echo "$env_spec" | cut -d: -f1)
        env_assignment=$(echo "$env_spec" | cut -d: -f2-)

        # Skip if not for this server
        [[ "$env_server" != "$name" ]] && continue

        local env_key env_value
        env_key=$(echo "$env_assignment" | cut -d= -f1)
        env_value=$(echo "$env_assignment" | cut -d= -f2-)

        # Resolve {PORT_servicename} placeholders
        while [[ "$env_value" =~ \{PORT_([^}]+)\} ]]; do
          local service_name="${BASH_REMATCH[1]}"
          local port
          port=$(hatch_resolve_port "$service_name") || _die "Failed to resolve port for $service_name in MCP env"
          env_value=$(echo "$env_value" | sed "s/{PORT_${service_name}}/${port}/g")
        done

        # Resolve {DOCKER_HOST} placeholder
        if [[ "$env_value" == *"{DOCKER_HOST}"* ]]; then
          local docker_host
          docker_host=$(_docker_host)
          env_value=$(echo "$env_value" | sed "s/{DOCKER_HOST}/${docker_host}/g")
        fi

        if [[ $has_env -eq 0 ]]; then
          env_json="\"$env_key\": \"$env_value\""
          has_env=1
        else
          env_json="$env_json, \"$env_key\": \"$env_value\""
        fi
      done < <(_parse_services MCP_ENV)
    fi

    # Build server entry
    servers_json="$servers_json \"$name\": {\"command\": \"$command\", \"args\": [$args_json]"
    if [[ $has_env -eq 1 ]]; then
      servers_json="$servers_json, \"env\": {$env_json}"
    fi
    servers_json="$servers_json}"

    _info "Configured MCP server: $name"
  done < <(_parse_services MCP_SERVERS)

  servers_json="$servers_json}"

  # Write to ~/.claude.json under projects.<project_path>.mcpServers
  # This keeps the project's .mcp.json untouched
  local project_path
  project_path=$(pwd -P)
  local claude_json="$HOME/.claude.json"
  local tmp_file="${claude_json}.tmp.$$"
  local lock_dir="${claude_json}.lock"

  _require jq "Install with: brew install jq (macOS) or apt install jq (Linux)"

  # Acquire lock (mkdir is atomic on all filesystems)
  local lock_attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_attempts=$((lock_attempts + 1))
    if [[ $lock_attempts -ge 50 ]]; then
      _die "Timed out waiting for lock on $claude_json (stale lock? remove $lock_dir)"
    fi
    sleep 0.1
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lock_dir' 2>/dev/null" EXIT

  # Read existing config or start fresh
  local existing='{}'
  if [[ -f "$claude_json" ]]; then
    if ! existing=$(jq '.' "$claude_json" 2>/dev/null); then
      _warn "~/.claude.json contains invalid JSON, backing up to ~/.claude.json.bak"
      cp "$claude_json" "${claude_json}.bak"
      existing='{}'
    fi
  fi

  # Merge mcpServers into the project entry and write atomically
  echo "$existing" | jq --argjson servers "$servers_json" --arg path "$project_path" \
    '.projects[$path].mcpServers = $servers' > "$tmp_file" \
    || { rm -f "$tmp_file"; rmdir "$lock_dir" 2>/dev/null; _die "Failed to write MCP config"; }

  mv "$tmp_file" "$claude_json"

  # Release lock
  rmdir "$lock_dir" 2>/dev/null
  trap - EXIT

  _success "Written MCP servers to ~/.claude.json (project: $project_path)"
}
