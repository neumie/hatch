#!/usr/bin/env bash
# mcp.sh - MCP server configuration generation
# Depends on: core.sh, manifest.sh, ports.sh
#
# .mcp.json is a GENERATED file (like docker-compose.override.yaml).
# All MCP servers are declared in hatch.conf via MCP_SERVERS and MCP_ENV.
# hatch setup always regenerates .mcp.json from those declarations.

# hatch_generate_mcp_config
# Reads MCP_SERVERS and MCP_ENV from manifest
# Generates .mcp.json with resolved port placeholders
# MCP_SERVERS format: "name:command:args" (one per line)
# MCP_ENV format: "server_name:KEY=value" (one per line, supports {PORT_x} placeholders)
hatch_generate_mcp_config() {
  if [[ -z "${MCP_SERVERS:-}" ]]; then
    _info "No MCP_SERVERS defined, skipping .mcp.json generation"
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

  # Write .mcp.json (pretty-printed if python3 available)
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
servers = json.loads(sys.argv[1])
with open('.mcp.json', 'w') as f:
    json.dump({'mcpServers': servers}, f, indent=2)
    f.write('\n')
" "$servers_json"
  else
    printf '{\n  "mcpServers": %s\n}\n' "$servers_json" > .mcp.json
  fi

  _success "Generated .mcp.json"
}
