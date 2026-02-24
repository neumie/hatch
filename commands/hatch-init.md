---
description: Set up hatch configuration for the current project
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep]
---

# Hatch Init - AI-Guided Setup

You are helping the user set up hatch (a workspace-isolated dev environment manager) for their project. Your job is to generate a complete, working `hatch.conf` by combining auto-detection with intelligent questions.

## Workflow

### Step 1: Run the auto-detection wizard

```bash
hatch init --auto
```

This generates a baseline `hatch.conf` with auto-detected values (project name, package manager, docker services, dev servers, migration tool, etc.).

### Step 2: Read the generated config

Read the generated config file (check `.hatch/hatch.conf`, then `hatch.conf`). Identify which sections are populated and which are empty or missing.

### Step 3: Scan the project for gaps

For each empty/missing section, scan the project to build intelligent suggestions:

**PORT_TEMPLATES** (most important gap):
- Find all `.env.local`, `.dev.vars`, `.env.development` files in workspace directories
- Read each file and look for URL patterns containing `localhost` with port numbers
- Look for variable names referencing docker services (e.g., `*_API_URL`, `*_DATABASE_URL`)
- For each match, suggest a PORT_TEMPLATE entry replacing the hardcoded port with `{PORT_servicename}`

**SECRETS** (static env vars):
- In the same env files, identify values that are NOT URLs with ports — these are likely static secrets
- Common patterns: session tokens, project names, mode flags, API keys
- Suggest SECRETS entries for values that should be consistent across workspaces

**MCP_ENV**:
- If MCP_SERVERS is configured, the MCP server likely needs environment variables
- Check if the MCP entry point file imports/uses env vars (read the source)
- Suggest MCP_ENV entries with `{PORT_servicename}` placeholders for URLs

**DOCKER_ENV**:
- Check if any docker service needs to reference another service's port
- Common pattern: contember-engine needing minio's endpoint URL

**SECRET_FILES**:
- List env files that should be preserved across workspaces via `~/.config/hatch/secrets/`
- These are typically the same files targeted by PORT_TEMPLATES and SECRETS

### Step 4: Present findings and ask questions

Show the user what you found and ask for confirmation. Be specific — show actual variable names and suggested values. Ask about anything ambiguous.

### Step 5: Edit the config

Apply confirmed values to `hatch.conf` using the Edit tool.

## hatch.conf Field Format Reference

All multi-value fields are **newline-separated strings** (NOT bash arrays). Each entry is indented with 2 spaces.

### PORT_TEMPLATES
Injects dynamic port values into .gitignored env files during `hatch setup`.
```
PORT_TEMPLATES="
  filepath:VAR_NAME=value_with_{PORT_servicename}_placeholder
"
```
**Rules:**
- Only target `.gitignore`d files (`.env.local`, `.dev.vars`) — NEVER tracked files
- Use `{PORT_servicename}` placeholders (e.g., `{PORT_postgres}`, `{PORT_contember-engine}`)
- Service names must match DOCKER_SERVICES or DEV_SERVERS entries exactly

### SECRETS
Static key-value pairs written to workspace files during setup.
```
SECRETS="
  filepath:KEY=value
"
```

### MCP_ENV
Environment variables for MCP servers. Supports `{PORT_servicename}` and `{DOCKER_HOST}` placeholders.
```
MCP_ENV="
  server_name:KEY=value
"
```

### DOCKER_ENV
Environment variable overrides for Docker services.
```
DOCKER_ENV="
  service_name:KEY=value
"
```

### SECRET_FILES
Files to seed into `~/.config/hatch/secrets/` for cross-workspace sharing.
```
SECRET_FILES="
  filepath
"
```

### DEV_SERVERS
Dev servers started by `hatch up`. Command must NOT be prefixed with the package manager.
```
DEV_SERVERS="
  name:directory:command:port_offset
"
```
- `{PORT}` placeholder in command is replaced with the allocated port
- For yarn workspaces: `workspace @scope/name dev --port {PORT}`
- Port offsets: start at 10, increment per server

### SETUP_STEPS
Space-separated ordered list. Built-in steps:
- `docker:up` / `docker:down` — container lifecycle
- `deps:install` — package manager install
- `migrate:execute` — run migrations
- `migrate:execute_until` — run migrations up to a version
- `data:import` — import seed data
- `custom:function_name` — call a function from hooks file

## Real-World Example (Contember + yarn workspaces)

```bash
PROJECT_NAME="crane-rental"
PACKAGE_MANAGER="yarn"

DOCKER_SERVICES="
  contember-engine:4000
  postgres:5432
  minio:9000,9001
"

DOCKER_EXTRAS="
  adminer:8080
  mailhog:8025
"

DOCKER_ENV="
  contember-engine:DEFAULT_S3_ENDPOINT=http://localhost:{PORT_minio}
"

DEV_SERVERS="
  admin:admin:workspace @crane-rental-management/admin dev --port {PORT} --strictPort --host 0.0.0.0:10
  scan:scan:workspace @crane-rental-management/scan dev --port {PORT} --strictPort --host 0.0.0.0:11
  worker:worker:workspace @crane-rental-management/worker dev --port {PORT}:12
"

SECRETS="
  admin/.env.local:VITE_CONTEMBER_ADMIN_SESSION_TOKEN=0000000000000000000000000000000000000000
  admin/.env.local:VITE_CONTEMBER_ADMIN_PROJECT_NAME=crane-rental-management
  scan/.env.local:VITE_CONTEMBER_ADMIN_SESSION_TOKEN=0000000000000000000000000000000000000000
  scan/.env.local:VITE_CONTEMBER_ADMIN_PROJECT_NAME=crane-rental-management
  scan/.env.local:VITE_MODE=local
"

PORT_TEMPLATES="
  admin/.env.local:VITE_CONTEMBER_ADMIN_API_BASE_URL=http://localhost:{PORT_contember-engine}
  admin/.env.local:VITE_WORKER_URL=http://localhost:{PORT_worker}
  scan/.env.local:VITE_CONTEMBER_ADMIN_API_BASE_URL=http://localhost:{PORT_contember-engine}
  scan/.env.local:VITE_WORKER_URL=http://localhost:{PORT_worker}
  worker/.dev.vars:CONTEMBER_API_URL=http://localhost:{PORT_contember-engine}/content/crane-rental-management/live
  worker/.dev.vars:ADMIN_URL=http://localhost:{PORT_admin}
"

MCP_SERVERS="
  crane-rental:npx:tsx mcp/host/src/index.ts
"

MCP_ENV="
  crane-rental:CONTEMBER_API_URL=http://localhost:{PORT_contember-engine}/content/crane-rental-management/live
  crane-rental:CONTEMBER_API_TOKEN=0000000000000000000000000000000000000000
  crane-rental:ENVIRONMENT=local
"

SECRET_FILES="
  admin/.env.local
  scan/.env.local
  worker/.dev.vars
"

MIGRATE_TOOL="contember"
MIGRATIONS_DIR="api/migrations"
MIGRATIONS_FILE_EXT="json"

DB_USER="contember"
DB_PASSWORD="contember"
DB_NAME="contember"

SETUP_STEPS="docker:up migrate:execute data:import custom:crane_rental_setup"

POST_INSTALL_CMD="yarn client:generate"
HOOKS_FILE="hatch.hooks.sh"
```

## Important Rules

1. PORT_TEMPLATES must only target `.gitignore`d files — never tracked files or structured configs
2. Service names in `{PORT_servicename}` must match the names in DOCKER_SERVICES or DEV_SERVERS exactly (including hyphens)
3. DEV_SERVER commands must NOT include the package manager prefix — hatch prepends it automatically
4. When suggesting PORT_TEMPLATE entries, use the actual URL patterns from existing env files as templates
5. Read the project's CLAUDE.md if it exists — it may have project-specific conventions
