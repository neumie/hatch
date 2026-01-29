#!/usr/bin/env bash
# db.sh - Database management commands
# Sources: manifest, ports

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
WORKSPACE_NAME=$(hatch_resolve_workspace)
hatch_load_manifest "$PROJECT_NAME"

# Generate and allocate ports
hatch_generate_ports "$WORKSPACE_NAME" "$PROJECT_NAME"
hatch_allocate_ports

SUBCOMMAND="${1:-shell}"
shift || true

# Get database port (try postgres first, then others)
DB_PORT=$(hatch_resolve_port "postgres" 2>/dev/null || hatch_resolve_port "mysql" 2>/dev/null || echo "5432")
DB_USER="${DB_USER:-postgres}"
DB_PASS="${DB_PASS:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

case "$SUBCOMMAND" in
  shell|psql)
    _info "Connecting to PostgreSQL on port $DB_PORT"
    PGPASSWORD="$DB_PASS" psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME"
    ;;
  
  ui|adminer)
    ADMINER_PORT=$(hatch_resolve_port "adminer" 2>/dev/null || echo "")
    if [[ -z "$ADMINER_PORT" ]]; then
      _error "Adminer service not found in manifest"
      exit 1
    fi
    URL="http://localhost:$ADMINER_PORT"
    _info "Opening Adminer: $URL"
    _open_url "$URL"
    ;;
  
  dump)
    DUMP_FILE="${1:-dump-$(date +%Y%m%d-%H%M%S).sql}"
    _info "Dumping database to $DUMP_FILE"
    PGPASSWORD="$DB_PASS" pg_dump -h localhost -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" > "$DUMP_FILE"
    _success "Done: $DUMP_FILE"
    ;;
  
  restore)
    if [[ -z "$1" ]]; then
      _error "Usage: hatch db restore <dump-file.sql>"
      exit 1
    fi
    _info "Restoring database from $1"
    PGPASSWORD="$DB_PASS" psql -h localhost -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" < "$1"
    _success "Done"
    ;;
  
  *)
    echo "Usage: hatch db [shell|ui|dump|restore <file>]"
    echo ""
    echo "Commands:"
    echo "  shell          - Open psql shell"
    echo "  ui             - Open Adminer in browser"
    echo "  dump [file]    - Dump database to SQL file"
    echo "  restore <file> - Restore database from SQL file"
    exit 1
    ;;
esac
