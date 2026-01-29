#!/usr/bin/env bash
# data.sh - Data import/export with migration versioning
# Depends on: core.sh, manifest.sh, migrate.sh

# hatch_get_latest_migration
# Scans MIGRATIONS_DIR for latest migration version. Returns the version string.
# Requires MIGRATIONS_DIR, MIGRATIONS_FILE_EXT. Uses MIGRATIONS_VERSION_EXTRACT if set,
# otherwise extracts first 4 hyphen-separated segments from the filename.
hatch_get_latest_migration() {
  local migrations_dir="${MIGRATIONS_DIR:?MIGRATIONS_DIR not set}"
  local ext="${MIGRATIONS_FILE_EXT:?MIGRATIONS_FILE_EXT not set}"

  if [[ ! -d "$migrations_dir" ]]; then
    _warn "Migrations directory not found: $migrations_dir"
    return 1
  fi

  local latest_file
  latest_file=$(find "$migrations_dir" -type f -name "*.$ext" | sort -r | head -n 1)

  if [[ -z "$latest_file" ]]; then
    _warn "No migrations found in $migrations_dir"
    return 1
  fi

  local latest_version
  if [[ -n "${MIGRATIONS_VERSION_EXTRACT:-}" ]]; then
    latest_version=$(basename "$latest_file" | eval "$MIGRATIONS_VERSION_EXTRACT")
  else
    latest_version=$(basename "$latest_file" ".$ext" | cut -d- -f1-4)
  fi

  if [[ -z "$latest_version" ]]; then
    _warn "Could not extract version from: $latest_file"
    return 1
  fi

  echo "$latest_version"
}

# hatch_get_export_version
# Returns the version string from the latest export file, or fails if none found.
hatch_get_export_version() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"
  local export_file
  export_file=$(find "$data_dir" -type f -name "export-*.jsonl.gz" 2>/dev/null | sort -r | head -n 1)
  if [[ -z "$export_file" ]]; then
    return 1
  fi
  basename "$export_file" | sed 's/^export-//' | sed 's/\.jsonl\.gz$//'
}

# _resolve_migration_name VERSION
# Resolves a timestamp version to the full migration name (basename without extension)
_resolve_migration_name() {
  local version="$1"
  local migrations_dir="${MIGRATIONS_DIR:?MIGRATIONS_DIR not set}"
  local ext="${MIGRATIONS_FILE_EXT:?MIGRATIONS_FILE_EXT not set}"
  local match
  match=$(find "$migrations_dir" -name "${version}-*.$ext" | head -1)
  if [[ -n "$match" ]]; then
    basename "$match" ".$ext"
  else
    _warn "No migration file matching version '$version' in $migrations_dir; using version as-is"
    echo "$version"
  fi
}

# hatch_import_data
# Reads PROJECT_NAME. Looks for latest export file in $HATCH_DATA/$PROJECT_NAME/export-*.jsonl.gz
# If no export found: no-op
# If found: import data via DATA_IMPORT_CMD
# Migration orchestration is handled by SETUP_STEPS in hatch.conf
hatch_import_data() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"

  if [[ ! -d "$data_dir" ]]; then
    _info "No data directory found at: $data_dir"
    return 0
  fi

  # Find latest export file
  local export_file
  export_file=$(find "$data_dir" -type f -name "export-*.jsonl.gz" | sort -r | head -n 1)

  if [[ -z "$export_file" ]]; then
    _info "No export files found in $data_dir"
    return 0
  fi

  _header "Importing data from export"
  _info "Export file: $export_file"

  # Extract version from filename
  local export_version
  export_version=$(hatch_get_export_version)

  _info "Export version: $export_version"

  if [[ -z "${DATA_IMPORT_CMD:-}" ]]; then
    _die "DATA_IMPORT_CMD not set. Configure it in hatch.conf to import data."
  fi

  _info "Importing data"
  if ! eval "$DATA_IMPORT_CMD" "$export_file"; then
    _error "Import command failed"
    return 1
  fi

  _success "Data import complete"
}

# hatch_export_data
# Reads PROJECT_NAME, MIGRATIONS_DIR, MIGRATIONS_FILE_EXT
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

  if [[ -z "${DATA_EXPORT_CMD:-}" ]]; then
    _die "DATA_EXPORT_CMD not set. Configure it in hatch.conf to export data."
  fi

  _info "Exporting data"
  if ! eval "$DATA_EXPORT_CMD" "$export_path"; then
    _error "Export command failed"
    return 1
  fi

  if [[ -f "$export_path" ]]; then
    _success "Data exported to: $export_path"
  else
    _error "Export file not created: $export_path"
    return 1
  fi
}
