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
- Find all gitignored files matching `.env*`, `.dev.vars`, `*.local` in all subdirectories — also check `scripts/`, `.hatch/`, and any workspace dirs
- Read each file and look for URL patterns containing `localhost` with port numbers
- Look for variable names referencing docker services (e.g., `*_API_URL`, `*_DATABASE_URL`)
- For each match, suggest a PORT_TEMPLATE entry replacing the hardcoded port with `{PORT_servicename}`

**SECRETS** (non-sensitive, development-only static values):
- In the same env files, identify values that are NOT URLs with ports and are safe to commit to git
- Common patterns: placeholder tokens (all-zeros like `0000000000000000000000000000000000000000`), project names, mode flags (`MODE=local`)
- **Never** include real API keys, credentials, passwords, or service tokens — if a value looks like a real credential (e.g., Cloudflare, Postmark, AWS, OAuth keys), skip it and ensure the file is listed in SECRET_FILES instead
- Suggest SECRETS entries only for values that are both consistent across workspaces AND safe to store in hatch.conf (which is committed to git)

**MCP_ENV**:
- If MCP_SERVERS is configured, the MCP server likely needs environment variables
- Check if the MCP entry point file imports/uses env vars (read the source)
- Suggest MCP_ENV entries with `{PORT_servicename}` placeholders for URLs

**DOCKER_ENV**:
- Check if any docker service needs to reference another service's port
- Common pattern: contember-engine needing minio's endpoint URL

**Multi-port services**:
- Read `docker-compose.yml` `ports:` mapping for each service
- If a service exposes multiple ports (e.g., minio: 9000 for API + 9001 for console), capture ALL ports using comma syntax: `minio:9000,9001`
- The first port becomes the primary `{PORT_servicename}` placeholder

**Validate DEV_SERVERS**:
- For each auto-detected dev server, check if any env file actually references its port (via `PORT_<servername>` pattern or `localhost:<port>`)
- Flag servers that nothing depends on and ask the user whether they're actually needed — auto-detection may be over-inclusive

**SECRET_FILES** (the mechanism for sensitive values):
- List env files that should be preserved across workspaces via `~/.config/hatch/secrets/`
- These are typically the same files targeted by PORT_TEMPLATES and SECRETS
- **Any env file containing real API keys, credentials, or service tokens MUST be listed here** — this is how sensitive values are shared across workspaces without being written into hatch.conf. The user populates these files once, runs `hatch seed`, and subsequent workspaces get them via symlinks
- Also check `.hatch/` for env files used by hooks (e.g., `.hatch/.env.local` for hook configuration like `DEV_EMAIL_DOMAIN`)

**Docker-based CLIs** (critical for hooks generation):
- Read `package.json` `scripts`; identify any that wrap `docker compose run` (e.g., `"contember": "docker compose run --rm contember-cli"`)
- For each, note the Docker service name and cross-reference with `docker-compose.yml` to discover: pre-configured env vars, volume mounts (determines file path accessibility), and available commands
- This determines how CLI commands work in hooks — the container already has env vars configured, and only volume-mounted paths are accessible

### Step 3.5: Hooks & Setup Workflow

Ask the user about their setup workflow beyond the basics. Suggest common patterns:

- Need to import seed data after migrations? → `data:import` step + `DATA_IMPORT_CMD`
- Need to sanitize emails in imported data (for dev safety)? → `custom:` hook
- Need to create test users or invite imported users? → `custom:` hook
- Need to run migrations in stages (migrate up to a version, import data, then finish)? → `migrate:execute_until` + `data:import` + `migrate:execute`
- Any other project-specific setup steps? → `custom:function_name`

For each custom step identified, you will generate the corresponding function in the hooks file (Step 6). Note the function names — they must match the `custom:function_name` entries in `SETUP_STEPS` and the `DATA_IMPORT_CMD`/`DATA_EXPORT_CMD` values.

### Step 4: Present findings and ask questions

Show the user what you found and ask for confirmation. Be specific — show actual variable names and suggested values. Ask about anything ambiguous.

Based on the user's answers about their workflow (from Step 3.5), construct the full `SETUP_STEPS` string. Show the proposed order and explain what each step does. Example progression:
- Simple: `docker:up deps:install migrate:execute`
- With data import: `docker:up deps:install migrate:execute_until data:import migrate:execute`
- With custom hooks: `docker:up deps:install migrate:execute_until data:import custom:sanitize_emails migrate:execute custom:setup_users`

### Step 5: Edit the config

Apply confirmed values to `hatch.conf` using the Edit tool or equivalent.

### Step 6: Generate the hooks file

If any `custom:` steps, `DATA_IMPORT_CMD`, or `DATA_EXPORT_CMD` were configured, generate a working hooks file. Choose `.sh` or `.ts` based on the project's language (TypeScript projects should prefer `.ts`).

**Process:**
1. Read the project's existing code to understand APIs, endpoints, and service interactions
2. Validate CLI invocations: check `package.json` scripts and `docker-compose.yml` to confirm correct command syntax, available subcommands, and pre-configured environment variables. Never guess CLI flags — verify they exist.
3. For each function needed (`DATA_IMPORT_CMD`, `DATA_EXPORT_CMD`, `custom:*` functions), write a working implementation based on project context
4. Use the hatch hooks API (see reference below) for port resolution and logging
5. Place the file where `HOOKS_FILE` points (typically project root or `.hatch/`)

**The hooks file must:**
- Implement every function referenced by `SETUP_STEPS` `custom:*` entries, `DATA_IMPORT_CMD`, and `DATA_EXPORT_CMD`
- Use `hatch_resolve_port` (bash) or `process.env.HATCH_PORT_<name>` (TS) for dynamic ports — never hardcode ports
- Use `_docker_host` (bash) or platform detection (TS) when services inside Docker need to reach the host
- Handle errors gracefully — log warnings rather than crashing setup for non-critical failures
- `_pkg_run`: use for commands defined in `package.json` scripts (e.g., `_pkg_run contember data:export` when `"contember"` is a script). Do NOT use for arbitrary node_modules binaries — use `npx` / `bunx` for those (e.g., `npx tsx`, `npx prisma`). To decide: check `package.json` scripts.
- For Docker-wrapped CLIs (script runs `docker compose run`): the container has its own env vars — never pass redundant flags (e.g., `--api-url`, `--api-token`). File paths must be project-relative (within volume mount).
- For data import hooks with Docker CLIs: the export file path (`$1`) is an absolute host path outside the volume mount — prefer using the service's HTTP API directly (see example), or copy the file into the project dir first

## Hooks File Reference

### Bash hooks (`hatch.hooks.sh`)

Sourced directly into the hatch shell — all hatch utility functions are available.

**Port resolution:**
```bash
port=$(hatch_resolve_port "service-name")  # Returns allocated host port
```

**Logging functions:**
```bash
_header "Section title"     # Bold === Section title ===
_info "Status message"      # Blue [info] prefix
_warn "Warning message"     # Yellow [warn] prefix
_success "Done message"     # Green [ok] prefix
_die "Fatal error"          # Red [error] prefix, then exit 1
```

**Other utilities:**
```bash
_pkg_run command args...    # Run package.json scripts via package manager (NOT for arbitrary binaries — use npx for those)
_docker_host                # Returns host address reachable from Docker (host.docker.internal on macOS)
```

**Function signatures:**
```bash
# DATA_IMPORT_CMD — receives export file path as $1
my_import() {
  local export_file="$1"
  local port=$(hatch_resolve_port "service-name")
  # ... import logic
}

# DATA_EXPORT_CMD — receives temp file path as $1, must write output there
my_export() {
  local export_path="$1"
  # ... export logic writing to $export_path
}

# custom:my_setup — no arguments, called during setup
my_setup() {
  local port=$(hatch_resolve_port "service-name")
  # ... setup logic
}
```

### TypeScript hooks (`hatch.hooks.ts`)

All functions must be `export async function` with snake_case names. Hatch generates bash wrappers that delegate to `lib/ts-hook-runner.ts`.

**Port resolution:**
```typescript
// Hyphens/dots in service names become underscores in env var
const port = process.env.HATCH_PORT_contember_engine; // or PORT_contember_engine
```

**Platform detection (for Docker host access):**
```typescript
const dockerHost = process.platform === "darwin" ? "host.docker.internal" : "172.17.0.1";
```

**Package manager detection:**
```typescript
const pkgCmd = process.env.PACKAGE_MANAGER === "bun" ? "bunx" : "npx";
```

**Function signatures:**
```typescript
// DATA_IMPORT_CMD
export async function my_import(exportFile: string) {
  const port = process.env.HATCH_PORT_service_name;
  // ... import logic using fetch()
}

// DATA_EXPORT_CMD
export async function my_export(exportPath: string) {
  const { execFileSync } = await import("child_process");
  // ... export logic writing to exportPath
}

// custom:my_setup
export async function my_setup() {
  const port = process.env.HATCH_PORT_service_name;
  // ... setup logic using fetch()
}
```

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

### DATA_IMPORT_CMD / DATA_EXPORT_CMD
Custom commands (typically hook functions) for importing/exporting seed data.
```
DATA_IMPORT_CMD="function_name"
DATA_EXPORT_CMD="function_name"
```
- Called by `data:import` and `data:export` setup steps
- Import receives the export file path as first argument
- Export receives a temp file path to write to
- Functions must be defined in the hooks file (`HOOKS_FILE`)

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

DATA_IMPORT_CMD="crane_rental_import"
DATA_EXPORT_CMD="crane_rental_export"
# ^ Import uses HTTP API (curl) to avoid Docker volume mount path issues
# ^ Export uses _pkg_run — works because hatch creates export_path in project dir

SETUP_STEPS="docker:up deps:install migrate:execute_until data:import migrate:execute custom:crane_rental_setup"

POST_INSTALL_CMD="yarn client:generate"
HOOKS_FILE="hatch.hooks.sh"
```

## Important Rules

1. PORT_TEMPLATES must only target `.gitignore`d files — never tracked files or structured configs
2. Service names in `{PORT_servicename}` must match the names in DOCKER_SERVICES or DEV_SERVERS exactly (including hyphens)
3. DEV_SERVER commands must NOT include the package manager prefix — hatch prepends it automatically
4. When suggesting PORT_TEMPLATE entries, use the actual URL patterns from existing env files as templates
5. Read the project's CLAUDE.md or equivalent if it exists — it may have project-specific conventions
