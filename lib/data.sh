#!/usr/bin/env bash
# data.sh - Data import/export with migration versioning
# Depends on: core.sh, manifest.sh, migrate.sh

# hatch_get_latest_migration
# Scans MIGRATIONS_DIR for the latest timestamped migration version. Returns the version string.
# Non-migration metadata such as Contember's snapshot.json and state/*.json is ignored.
# Requires MIGRATIONS_DIR, MIGRATIONS_FILE_EXT. Uses MIGRATIONS_VERSION_EXTRACT if set,
# otherwise extracts first 4 hyphen-separated segments from the filename.
hatch_get_latest_migration() {
  local migrations_dir="${MIGRATIONS_DIR:?MIGRATIONS_DIR not set}"
  local ext="${MIGRATIONS_FILE_EXT:?MIGRATIONS_FILE_EXT not set}"

  if [[ ! -d "$migrations_dir" ]]; then
    _warn "Migrations directory not found: $migrations_dir"
    return 1
  fi

  local migration_pattern
  migration_pattern='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.'"$ext"

  local latest_file
  latest_file=$(find "$migrations_dir" -type f -name "$migration_pattern" | sort -r | head -n 1)

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

# _read_export_version FILE
# Reads schemaVersion from the export file header (first JSON line).
# Falls back to filename-based version if header parsing fails.
_read_export_version() {
  local export_file="$1"
  local schema_version
  schema_version=$(gunzip -c "$export_file" 2>/dev/null | head -1 | python3 -c "import sys,json; print(json.load(sys.stdin)[1]['schemaVersion'])" 2>/dev/null || true)
  if [[ -n "$schema_version" ]]; then
    echo "$schema_version"
    return 0
  fi
  basename "$export_file" | sed 's/^export-//' | sed 's/\.jsonl\.gz$//'
}

# _export_version_on_branch VERSION
# Returns 0 if VERSION resolves to a migration file in MIGRATIONS_DIR, 1 otherwise.
# Returns 0 when MIGRATIONS_DIR is not configured (nothing to compare against).
_export_version_on_branch() {
  local version="$1"
  [[ -z "$version" ]] && return 1
  if [[ -z "${MIGRATIONS_DIR:-}" ]] || [[ ! -d "$MIGRATIONS_DIR" ]]; then
    return 0
  fi
  local match
  match=$(find "$MIGRATIONS_DIR" -name "${version}-*" -type f 2>/dev/null | head -1)
  [[ -n "$match" ]]
}

# _find_latest_compatible_export
# Walks exports newest → oldest and echoes the path of the first one whose
# schemaVersion resolves to an existing migration in MIGRATIONS_DIR. This lets
# us pick an older compatible export instead of failing when the newest export
# comes from a branch with newer migrations than the current one. Returns 1
# with no output when no compatible export exists.
_find_latest_compatible_export() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"
  [[ -d "$data_dir" ]] || return 1

  local export_file version
  while IFS= read -r export_file; do
    version=$(_read_export_version "$export_file")
    if _export_version_on_branch "$version"; then
      echo "$export_file"
      return 0
    fi
  done < <(find "$data_dir" -type f -name "export-*.jsonl.gz" 2>/dev/null | sort -r)

  return 1
}

# hatch_get_export_version
# Returns the schemaVersion of the newest export compatible with the current
# branch's MIGRATIONS_DIR. Returns 1 if no compatible export exists.
hatch_get_export_version() {
  local export_file
  export_file=$(_find_latest_compatible_export) || return 1
  _read_export_version "$export_file"
}

# _resolve_migration_name VERSION
# Resolves a timestamp version to the full migration name (basename without extension)
_resolve_migration_name() {
  local version="$1"
  local migrations_dir="${MIGRATIONS_DIR:?MIGRATIONS_DIR not set}"
  local match
  # Search for any file extension (migrations can be .json or .ts content migrations)
  match=$(find "$migrations_dir" -name "${version}-*" -type f | head -1)
  if [[ -n "$match" ]]; then
    local base
    base=$(basename "$match")
    # Strip any extension
    echo "${base%.*}"
  else
    _warn "No migration file matching version '$version' in $migrations_dir; using version as-is"
    echo "$version"
  fi
}

# hatch_import_data
# Reads PROJECT_NAME. Selects the newest export in $HATCH_DATA/$PROJECT_NAME
# whose schemaVersion resolves to a migration on the current branch, so older
# compatible exports can be used when the latest export is from a newer branch.
# No-op when no compatible export exists. Import is executed via DATA_IMPORT_CMD.
hatch_import_data() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"

  if [[ ! -d "$data_dir" ]]; then
    _info "No data directory found at: $data_dir"
    return 0
  fi

  local latest_export
  latest_export=$(find "$data_dir" -type f -name "export-*.jsonl.gz" 2>/dev/null | sort -r | head -n 1)

  if [[ -z "$latest_export" ]]; then
    _info "No export files found in $data_dir"
    return 0
  fi

  local export_file
  if ! export_file=$(_find_latest_compatible_export); then
    _warn "No export compatible with current branch schema in $data_dir"
    _warn "Latest export: $(basename "$latest_export") (schema: $(_read_export_version "$latest_export"))"
    _warn "Current branch has no migration matching this or any older export."
    return 0
  fi

  _header "Importing data from export"
  if [[ "$export_file" != "$latest_export" ]]; then
    _warn "Latest export $(basename "$latest_export") is newer than current branch schema"
    _info "Falling back to newest compatible export"
  fi
  _info "Export file: $export_file"

  local export_version
  export_version=$(_read_export_version "$export_file")
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

  # Write to a temp file in the project directory first.
  # This is necessary because the export command may run inside Docker where
  # only the project directory is volume-mounted (not the hatch data directory).
  local tmp_export=".hatch-export-tmp-${export_filename}"
  trap 'rm -f "$tmp_export"' RETURN

  _info "Exporting data"
  if ! eval "$DATA_EXPORT_CMD" "$tmp_export"; then
    _error "Export command failed"
    return 1
  fi

  if [[ ! -f "$tmp_export" ]]; then
    _error "Export file not created"
    return 1
  fi

  mv "$tmp_export" "$export_path"
  _success "Data exported to: $export_path"
}

# hatch_export_remote_data
# Exports data from a remote environment.
# Expects HATCH_REMOTE_URL and HATCH_REMOTE_TOKEN to be set.
# Uses DATA_REMOTE_EXPORT_CMD instead of DATA_EXPORT_CMD.
hatch_export_remote_data() {
  local data_dir="$HATCH_DATA/$PROJECT_NAME"

  mkdir -p "$data_dir"

  _header "Exporting data from remote"

  local latest_version
  latest_version=$(hatch_get_latest_migration) || latest_version="unknown"

  local export_filename="export-${latest_version}.jsonl.gz"
  local export_path="$data_dir/$export_filename"

  if [[ -z "${DATA_REMOTE_EXPORT_CMD:-}" ]]; then
    _die "DATA_REMOTE_EXPORT_CMD not set. Configure it in hatch.conf to export from remote environments."
  fi

  export HATCH_REMOTE_URL
  export HATCH_REMOTE_TOKEN

  # Write to a temp file in the project directory first.
  # This is necessary because the export command may run inside Docker where
  # only the project directory is volume-mounted (not the hatch data directory).
  local tmp_export=".hatch-export-tmp-${export_filename}"
  trap 'rm -f "$tmp_export"' RETURN

  _info "Exporting data (remote: $HATCH_REMOTE_URL)"
  if ! eval "$DATA_REMOTE_EXPORT_CMD" "$tmp_export"; then
    _error "Remote export command failed"
    return 1
  fi

  if [[ ! -f "$tmp_export" ]]; then
    _error "Export file not created"
    return 1
  fi

  mv "$tmp_export" "$export_path"
  _success "Data exported to: $export_path"
}
