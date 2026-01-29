#!/usr/bin/env bash
# data.sh - Data import/export with migration versioning
# Depends on: core.sh, manifest.sh, migrate.sh

# hatch_get_latest_migration
# Scans MIGRATIONS_DIR for latest migration version. Returns the version string.
hatch_get_latest_migration() {
  local migrations_dir="${MIGRATIONS_DIR:-api/migrations}"

  if [[ ! -d "$migrations_dir" ]]; then
    _warn "Migrations directory not found: $migrations_dir"
    return 1
  fi

  # Find all migration files and extract versions
  # Assumes format: YYYY-MM-DD-HHMMSS-*.json or similar timestamped format
  local latest_version
  latest_version=$(find "$migrations_dir" -type f -name "*.json" | sort -r | head -n 1 | xargs basename | sed 's/\.json$//' | cut -d- -f1-4)

  if [[ -z "$latest_version" ]]; then
    _warn "No migrations found in $migrations_dir"
    return 1
  fi

  echo "$latest_version"
}

# hatch_import_data
# Reads PROJECT_NAME. Looks for latest export file in $HATCH_DATA/$PROJECT_NAME/export-*.jsonl.gz
# If no export found: just run migrations
# If found: extract version, run migrations up to that version, import via curl POST to engine's /import
# endpoint, then run remaining migrations
hatch_import_data() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"

  if [[ ! -d "$data_dir" ]]; then
    _info "No data directory found at: $data_dir"
    _info "Running migrations only"
    hatch_migrate execute
    return 0
  fi

  # Find latest export file
  local export_file
  export_file=$(find "$data_dir" -type f -name "export-*.jsonl.gz" | sort -r | head -n 1)

  if [[ -z "$export_file" ]]; then
    _info "No export files found in $data_dir"
    _info "Running migrations only"
    hatch_migrate execute
    return 0
  fi

  _header "Importing data from export"
  _info "Export file: $export_file"

  # Extract version from filename: export-YYYY-MM-DD-HHMMSS.jsonl.gz
  local export_version
  export_version=$(basename "$export_file" | sed 's/^export-//' | sed 's/\.jsonl\.gz$//')

  _info "Export version: $export_version"

  # Check if custom import command is configured
  if [[ -n "${DATA_IMPORT_CMD:-}" ]]; then
    _info "Using custom import command"
    eval "$DATA_IMPORT_CMD" "$export_file"
    _success "Data import complete"
    return 0
  fi

  # Default: Contember-specific import logic
  _info "Using Contember import (default)"

  # Get Contember engine port - try common service names
  local engine_port
  engine_port=$(hatch_resolve_port "contember-engine" 2>/dev/null) || \
    engine_port=$(hatch_resolve_port "engine" 2>/dev/null) || \
    engine_port="${PORT_contember_engine:-${PORT_engine:-1481}}"

  # Get API token
  local api_token="${CONTEMBER_API_TOKEN:-0000000000000000000000000000000000000000}"

  # Import via HTTP POST (gzipped NDJSON upload)
  _info "Importing to http://localhost:$engine_port/import"

  if ! curl -s --fail -X POST \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/x-ndjson" \
    -H "Content-Encoding: gzip" \
    -T "$export_file" \
    "http://localhost:$engine_port/import"; then
    _error "Import failed"
    return 1
  fi
  echo ""

  _success "Data import complete"

  # Run any remaining migrations
  _info "Running migrations"
  hatch_migrate execute
}

# hatch_export_data
# Reads PROJECT_NAME and MIGRATIONS_DIR (default "api/migrations")
# Determines latest migration version from file listing
# Runs export command and moves to $HATCH_DATA/$PROJECT_NAME/
# Prints export path
hatch_export_data() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"

  # Create data directory if it doesn't exist
  mkdir -p "$data_dir"

  _header "Exporting data"

  # Get latest migration version
  local latest_version
  latest_version=$(hatch_get_latest_migration) || latest_version="unknown"

  local export_filename="export-${latest_version}.jsonl.gz"
  local export_path="$data_dir/$export_filename"

  # Check if custom export command is configured
  if [[ -n "${DATA_EXPORT_CMD:-}" ]]; then
    _info "Using custom export command"
    eval "$DATA_EXPORT_CMD" "$export_path"
    _success "Data exported to: $export_path"
    return 0
  fi

  # Default: Contember-specific export logic
  _info "Using Contember export (default)"
  _info "Migration version: $latest_version"

  # Run export command
  _pkg_run contember data:export --output "$export_filename"

  # Move to data directory
  if [[ -f "$export_filename" ]]; then
    mv "$export_filename" "$export_path"
    _success "Data exported to: $export_path"
  else
    _error "Export file not found: $export_filename"
    return 1
  fi
}
