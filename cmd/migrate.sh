#!/usr/bin/env bash
# migrate.sh - Database migration commands
# Sources: manifest, migrate

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/migrate.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
hatch_load_manifest "$PROJECT_NAME"

# Pass all arguments to hatch_migrate
SUBCOMMAND="${1:-execute}"
shift || true

hatch_migrate "$SUBCOMMAND" "$@"
