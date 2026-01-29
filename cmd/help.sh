#!/usr/bin/env bash
# help.sh - Display usage information

cat << 'HELP'
Hatch - Workspace-isolated development environment manager

USAGE:
  hatch <command> [options]

COMMANDS:
  setup              Set up project (install deps, start docker, run migrations)
  run [services...]  Start dev servers (use 'hatch stop' to shut down)
  stop               Stop all services (dev servers + Docker)
  status             Show status of Docker and dev servers
  logs [services...] View Docker service logs (all or specific services)
  open [service]     Open service URL in browser
  
  db shell           Open database shell (psql)
  db ui              Open database UI (Adminer)
  db dump [file]     Dump database to SQL file
  db restore <file>  Restore database from SQL file
  
  migrate execute    Run pending migrations
  migrate diff       Create new migration
  migrate status     Show migration status
  migrate amend      Amend latest migration (if supported)
  
  export             Export project data to fixtures
  archive [--force]  Clean up workspace (remove containers, volumes, files)
  
  init               Initialize hatch.conf for current project
  doctor             Check system dependencies
  update             Update hatch to latest version
  help               Show this help message

EXAMPLES:
  hatch setup                    # Full project setup
  hatch run                      # Start all dev servers
  hatch run admin scan           # Start only admin and scan servers
  hatch status                   # Check what's running
  hatch open admin               # Open admin in browser
  hatch db shell                 # Connect to database
  hatch migrate execute          # Run migrations
  hatch archive                  # Clean up workspace

CONFIGURATION:
  Hatch looks for configuration in:
    1. ./hatch.conf (project root)
    2. ~/.hatch/projects/<project-name>.conf (user config)
  
  Run 'hatch init' to create a configuration file.

DIRECTORIES:
  HATCH_HOME:    ~/.hatch           (installation directory)
  HATCH_SECRETS: ~/.hatch/secrets   (secret files per project)
  HATCH_DATA:    ~/.hatch/data      (data exports per project)
  HATCH_PROJECTS: ~/.hatch/projects (project configurations)

MORE INFO:
  Documentation: https://github.com/neumie/hatch
  Issues: https://github.com/neumie/hatch/issues
HELP
