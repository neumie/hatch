#!/usr/bin/env bash
# secrets.sh - Generic secret linking and port template injection
# Depends on: core.sh, manifest.sh, ports.sh

# hatch_link_secrets
# Reads PROJECT_NAME. Walks $HATCH_SECRETS/$PROJECT_NAME/ directory.
# For each file found:
# - Compute relative path from secrets dir
# - If the file path matches a PORT_TEMPLATES entry, copy (not symlink) - it needs port injection
# - Otherwise, create symlink into workspace mirroring directory structure
# - Create parent dirs as needed
hatch_link_secrets() {
  local secrets_dir="$HATCH_SECRETS/$PROJECT_NAME"

  if [[ ! -d "$secrets_dir" ]]; then
    _warn "No secrets directory found at: $secrets_dir"
    return 0
  fi

  _header "Linking secrets"

  # Collect port template files for comparison
  local template_files=()
  if [[ -n "${PORT_TEMPLATES:-}" ]]; then
    while IFS= read -r template_spec; do
      [[ -z "$template_spec" ]] && continue
      # Parse format: "file_path:VAR_NAME=value_template"
      local file_path
      file_path=$(echo "$template_spec" | cut -d: -f1)
      template_files+=("$file_path")
    done < <(_parse_services PORT_TEMPLATES)
  fi

  # Walk secrets directory and link/copy files
  local secret_count=0
  while IFS= read -r secret_file; do
    # Skip directories
    [[ -d "$secret_file" ]] && continue

    # Compute relative path from secrets dir
    local rel_path="${secret_file#$secrets_dir/}"

    # Determine target path in workspace
    local target_path="$PWD/$rel_path"

    # Check if this file is in PORT_TEMPLATES
    local is_template=0
    local template_entry
    for template_entry in "${template_files[@]}"; do
      if [[ "$rel_path" == "$template_entry" ]]; then
        is_template=1
        break
      fi
    done

    # Create parent directory if needed
    local parent_dir
    parent_dir=$(dirname "$target_path")
    mkdir -p "$parent_dir"

    if [[ $is_template -eq 1 ]]; then
      # Copy file (will be modified by hatch_inject_ports)
      cp "$secret_file" "$target_path"
      _info "Copied (template): $rel_path"
    else
      # Create symlink
      # Remove existing symlink or file if present
      if [[ -e "$target_path" ]] || [[ -L "$target_path" ]]; then
        rm -f "$target_path"
      fi

      ln -s "$secret_file" "$target_path"
      _info "Linked: $rel_path"
    fi

    secret_count=$((secret_count + 1))
  done < <(find "$secrets_dir" -type f)

  if [[ $secret_count -eq 0 ]]; then
    _warn "No secret files found in $secrets_dir"
  else
    _success "Linked/copied $secret_count secret file(s)"
  fi
}

# hatch_inject_ports
# Reads PORT_TEMPLATES from manifest. Format per entry: "file_path:VAR_NAME=value_template"
# For each template: resolve {PORT_servicename} placeholders to actual ports
# If file exists: update/replace the line matching VAR_NAME
# If file doesn't exist or line doesn't exist: append it
# Use _sed_i for replacements (cross-platform)
hatch_inject_ports() {
  if [[ -z "${PORT_TEMPLATES:-}" ]]; then
    _info "No PORT_TEMPLATES defined, skipping port injection"
    return 0
  fi

  _header "Injecting ports into templates"

  while IFS= read -r template_spec; do
    [[ -z "$template_spec" ]] && continue

    # Parse format: "file_path:VAR_NAME=value_template"
    local file_path var_assignment
    file_path=$(echo "$template_spec" | cut -d: -f1)
    var_assignment=$(echo "$template_spec" | cut -d: -f2-)

    # Split VAR_NAME and value_template
    local var_name value_template
    var_name=$(echo "$var_assignment" | cut -d= -f1)
    value_template=$(echo "$var_assignment" | cut -d= -f2-)

    # Resolve {PORT_servicename} placeholders
    local resolved_value="$value_template"
    while [[ "$resolved_value" =~ \{PORT_([^}]+)\} ]]; do
      local service_name="${BASH_REMATCH[1]}"
      local port
      port=$(hatch_resolve_port "$service_name") || _die "Failed to resolve port for $service_name"
      resolved_value=$(echo "$resolved_value" | sed "s/{PORT_${service_name}}/${port}/g")
    done

    # Check if file exists
    if [[ -f "$file_path" ]]; then
      # Match both KEY=value and KEY = "value" (TOML style with optional spaces/quotes)
      if grep -q "^${var_name}[[:space:]]*=" "$file_path" 2>/dev/null; then
        # Detect existing style: TOML uses spaces around = and quotes
        local existing_line
        existing_line=$(grep "^${var_name}[[:space:]]*=" "$file_path" | head -1)

        if echo "$existing_line" | grep -q "^${var_name} = \""; then
          # TOML style: KEY = "value"
          _sed_i "s|^${var_name} = \".*\"|${var_name} = \"${resolved_value}\"|" "$file_path"
        elif echo "$existing_line" | grep -q "^${var_name} = "; then
          # TOML style without quotes: KEY = value
          _sed_i "s|^${var_name} = .*|${var_name} = \"${resolved_value}\"|" "$file_path"
        else
          # .env style: KEY=value or KEY="value"
          _sed_i "s|^${var_name}=.*|${var_name}=${resolved_value}|" "$file_path"
        fi
        _info "Updated $var_name in $file_path"
      else
        # Append in the style matching the file extension
        case "$file_path" in
          *.toml)
            echo "${var_name} = \"${resolved_value}\"" >> "$file_path"
            ;;
          *)
            echo "${var_name}=${resolved_value}" >> "$file_path"
            ;;
        esac
        _info "Appended $var_name to $file_path"
      fi
    else
      # Create file with the line
      local parent_dir
      parent_dir=$(dirname "$file_path")
      mkdir -p "$parent_dir"
      case "$file_path" in
        *.toml)
          echo "${var_name} = \"${resolved_value}\"" > "$file_path"
          ;;
        *)
          echo "${var_name}=${resolved_value}" > "$file_path"
          ;;
      esac
      _info "Created $file_path with $var_name"
    fi
  done < <(_parse_services PORT_TEMPLATES)

  _success "Port injection complete"
}
