# AI Setup Guide: Generating hatch.conf

This guide teaches you how to analyze any project and generate a valid `hatch.conf` file. Follow these 10 steps in order.

## Step 1: Identify the Project

Read the project to understand what you're working with.

**Actions:**
- Read `README.md`, `package.json`, or equivalent project manifests
- Check `.git/config` or `git remote -v` to get the repository name
- Set `PROJECT_NAME` from the repo name (e.g., `github.com/user/my-app` → `my-app`)

**Output:** `PROJECT_NAME="project-name"`

---

## Step 2: Detect Package Manager

Identify which package manager is used by checking for lockfiles.

**Decision tree:**
- `yarn.lock` exists → `PACKAGE_MANAGER="yarn"`
- `pnpm-lock.yaml` exists → `PACKAGE_MANAGER="pnpm"`
- `package-lock.json` exists → `PACKAGE_MANAGER="npm"`
- `bun.lockb` exists → `PACKAGE_MANAGER="bun"`
- None exist → `PACKAGE_MANAGER="none"`

**Output:** `PACKAGE_MANAGER="yarn|pnpm|npm|bun|none"`

---

## Step 3: Extract Docker Services

Read Docker Compose files to identify services.

**Files to check:** `docker-compose.yaml`, `docker-compose.yml`, `compose.yaml`, `compose.yml`

**Categorize services:**

**DOCKER_SERVICES** (infrastructure - no web UI):
- `postgres`, `mysql`, `mongodb`, `redis`, `rabbitmq`, `elasticsearch`, etc.
- Extract container ports from `ports:` mapping (left side of `:`)

**DOCKER_EXTRAS** (web UIs for development):
- `mailhog`, `mailcatcher`, `adminer`, `pgadmin`, `redis-commander`, etc.
- Extract container ports similarly

**Example:**
```yaml
services:
  postgres:
    ports: ["5432:5432"]
  redis:
    ports: ["6379:6379"]
  mailhog:
    ports: ["8025:8025", "1025:1025"]
```

**Output:**
```bash
DOCKER_SERVICES=("postgres:5432" "redis:6379")
DOCKER_EXTRAS=("mailhog:8025,1025")
```

---

## Step 4: Identify Dev Servers

Scan the project for runnable applications.

**Detection patterns:**

| File/Pattern | Server Type | Default Command | Port Offset |
|--------------|-------------|-----------------|-------------|
| `vite.config.*` | Vite | `vite dev --host --port {PORT}` | 10 |
| `next.config.*` | Next.js | `next dev -p {PORT}` | 11 |
| `wrangler.toml` | Wrangler | `wrangler dev --port {PORT}` | 12 |
| `nuxt.config.*` | Nuxt | `nuxt dev --port {PORT}` | 13 |
| `nest-cli.json` | NestJS | `npm run start:dev` (check PORT env) | 14 |
| `manage.py` | Django | `python manage.py runserver {PORT}` | 15 |
| `Gemfile` + rails | Rails | `rails server -p {PORT}` | 16 |
| `package.json` dev/start | Node | Extract script, add port flag | 17+ |

**For each server, define:**
```bash
DEV_SERVERS=(
  "name:directory:command:port_offset"
)
```

**Example:**
```bash
DEV_SERVERS=(
  "web:apps/web:dev --port {PORT}:10"
  "api:apps/api:dev --port {PORT}:11"
  "worker:apps/worker:node index.js:12"
)
```

**Rules:**
- `{PORT}` is a placeholder - hatch replaces it with actual port
- `directory` is relative to project root
- `port_offset` must be unique and ≥10 (0-9 reserved for docker)
- **NEVER prefix commands with the package manager** (`yarn`, `pnpm`, `npm`, `bun`). Hatch's `_pkg_run` automatically prepends the package manager based on `PACKAGE_MANAGER`. Writing `yarn vite` in the command produces `yarn yarn vite` at runtime. Write the bare command instead (e.g., `vite`, `next dev`, `wrangler dev`).
- For monorepos using yarn workspaces, use `workspace <pkg> <cmd>` (not `yarn workspace ...`). For pnpm, use `--filter <pkg> <cmd>` (not `pnpm --filter ...`).
- **CRITICAL — avoid duplicate flags when delegating to package.json scripts:**
  When the command delegates to a package.json script (e.g., `workspace @scope/worker dev --port {PORT}`), the extra arguments are **appended** to whatever the `dev` script already contains. If `package.json` defines `"dev": "wrangler dev --env local ..."`, do NOT also pass `--env local` in the hatch.conf command — many CLIs (including wrangler) reject duplicate single-value flags with an error like `expects a single value, but received multiple`. Always read the target package.json `scripts` before writing the DEV_SERVERS entry to avoid passing the same flag twice. Only add flags in hatch.conf that are NOT already in the underlying script (like `--port {PORT}`).

---

## Step 5: Map Port Templates

Find **local-only environment files** that reference localhost URLs and templatize them.

**Files to check:**
- `.env.local`, `.env.development`, `.dev.vars`

**IMPORTANT — only target untracked, local-only env files:**
- **NEVER target files tracked by git.** Port injection modifies file contents in the working tree. If the file is tracked, this creates dirty diffs, risks accidentally committing local dev URLs over real production/staging values, and breaks other developers' environments. Only target files that are `.gitignore`d (e.g. `.env.local`, `.dev.vars`).
- Port templates use sed to replace lines matching `^VAR_NAME = ` or `^VAR_NAME=`. This is safe for flat key=value files where each key appears once.
- **NEVER target structured config files** like `wrangler.toml`, `next.config.js`, etc. These files often contain the same key in multiple sections (e.g. `[env.local]`, `[env.stage]`, `[env.prod]`), and the sed replacement will clobber **all** sections, destroying production/staging URLs.
- Wrangler workers already read `.dev.vars` at runtime for local development, so there is no need to also inject into `wrangler.toml`.

**Pattern matching:**
Look for URLs like:
- `http://localhost:3000`
- `http://127.0.0.1:5173`
- `localhost:8080`

**Replacement strategy:**
Replace port numbers with `{PORT_servicename}` where `servicename` matches:
1. A dev server name from `DEV_SERVERS`
2. A docker service name from `DOCKER_SERVICES` or `DOCKER_EXTRAS`

**Example input (`.env.local`):**
```
VITE_API_URL=http://localhost:4000/api
DATABASE_URL=postgresql://user:pass@localhost:5432/db
NEXT_PUBLIC_WEB_URL=http://localhost:3000
MAILHOG_URL=http://localhost:8025
```

**Output:**
```bash
PORT_TEMPLATES="
  .env.local:VITE_API_URL=http://localhost:{PORT_api}/api
  .env.local:DATABASE_URL=postgresql://user:pass@localhost:{PORT_postgres}/db
  .env.local:NEXT_PUBLIC_WEB_URL=http://localhost:{PORT_web}
  .env.local:MAILHOG_URL=http://localhost:{PORT_mailhog}
"
```

**Do NOT include in PORT_TEMPLATES:**
- Any file tracked by git — hatch will modify it on disk, creating dirty diffs and risking commits of local dev URLs over real values
- `wrangler.toml` — use `.dev.vars` instead (wrangler reads it automatically for local dev)
- `next.config.js` / `nuxt.config.ts` — use `.env.local` instead (frameworks read env files)

**How to verify:** Run `git ls-files <path>` — if it returns output, the file is tracked and must NOT be used as a port template.

---

## Step 6: Detect Migration Tool

Identify the database migration system.

**Detection patterns:**

| Evidence | Tool | Setup Command | Execute Command |
|----------|------|---------------|-----------------|
| `api/migrations/*.json` | Contember | `npm run contember migrations:diff` | `npm run contember migrations:execute` |
| `prisma/schema.prisma` | Prisma | `npx prisma migrate dev` | `npx prisma migrate deploy` |
| `knexfile.*` | Knex | `npx knex migrate:make` | `npx knex migrate:latest` |
| `drizzle.config.*` | Drizzle | `npx drizzle-kit generate` | `npx drizzle-kit migrate` |
| `migrations/` dir + `*.sql` | Custom SQL | N/A | Custom script |
| None found | none | N/A | N/A |

**Output:**
```bash
MIGRATE_TOOL="prisma"
MIGRATE_EXECUTE_CMD="npx prisma migrate deploy"
```

**For custom/unknown:**
```bash
MIGRATE_TOOL="custom"
MIGRATE_EXECUTE_CMD="./scripts/run-migrations.sh"
```

If uncertain, set `MIGRATE_TOOL="none"` and comment the section.

---

## Step 7: Extract Database Credentials

Read `docker-compose.yaml` environment variables to get DB credentials.

**Look for:**
- PostgreSQL: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
- MySQL: `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_ROOT_PASSWORD`
- MongoDB: `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`

**Example:**
```yaml
services:
  postgres:
    environment:
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: myapp_dev
```

**Output:**
```bash
DB_USER="myapp"
DB_PASS="secret"
DB_NAME="myapp_dev"
```

**Fallback:** If not found, use sensible defaults: `admin`/`password`/`dev_db`

---

## Step 8: Define Setup Steps

Determine the default setup sequence.

**Standard flow:**
```bash
SETUP_STEPS=("docker:up" "migrate:execute")
```

**Add conditionally:**
- `"data:import"` - if `exports/` or `seeds/` directory exists
- `"custom:bootstrap"` - if project has a bootstrap script (e.g., `scripts/setup.sh`)
- `"deps:install"` - if dependencies need explicit installation before other steps

**Common patterns:**

**Full-stack app with seeds:**
```bash
SETUP_STEPS=("docker:up" "deps:install" "migrate:execute" "data:import")
```

**Monorepo with custom setup:**
```bash
SETUP_STEPS=("docker:up" "custom:init_workspaces" "migrate:execute")
```

**No docker:**
```bash
SETUP_STEPS=("deps:install" "migrate:execute")
```

---

## Step 9: Detect MCP Servers

Check if the project has MCP (Model Context Protocol) servers that need workspace-specific configuration.

**Detection patterns:**

| Evidence | Meaning |
|----------|---------|
| `.mcp.json` in project root | Existing MCP config — extract server definitions |
| `mcp/` directory | MCP server source code |
| `@modelcontextprotocol/sdk` in package.json | MCP SDK dependency |
| `StdioServerTransport` in source files | stdio-based MCP server |

**For each MCP server, determine:**
1. **name**: Identifier for the MCP server (used as key in `mcpServers`)
2. **command**: The executable (e.g., `npx`, `node`, `python`)
3. **args**: Arguments passed to the command

**Then find environment variables the MCP server reads:**
- Search for `process.env.` in the MCP server source code
- Look for connection URLs that reference `localhost` with hardcoded ports
- These need `{PORT_servicename}` placeholders

**Example:**
If `mcp/host/src/context.ts` contains:
```typescript
const apiUrl = process.env.CONTEMBER_API_URL ?? 'http://localhost:1481/content/app/live'
const apiToken = process.env.CONTEMBER_API_TOKEN ?? '000...'
```

**Output:**
```bash
MCP_SERVERS="
  my-app:npx:tsx mcp/host/src/index.ts
"

MCP_ENV="
  my-app:CONTEMBER_API_URL=http://localhost:{PORT_contember-engine}/content/app/live
  my-app:CONTEMBER_API_TOKEN=0000000000000000000000000000000000000000
  my-app:ENVIRONMENT=local
"
```

**Rules:**
- `{PORT_servicename}` uses the same service names from `DOCKER_SERVICES` or `DEV_SERVERS`
- Each env entry is prefixed with the server name followed by a colon
- If no MCP servers found, omit both `MCP_SERVERS` and `MCP_ENV`

---

## Step 10: Add Hooks (if needed)

If the project requires custom logic that doesn't fit standard commands, create `hatch.hooks.sh`.

**When to add hooks:**
- Custom initialization logic
- Multi-database coordination
- External API setup
- Code generation before server starts

**Example `hatch.hooks.sh`:**
```bash
#!/usr/bin/env bash

# Called after all setup steps complete
post_setup() {
  echo "Running custom post-setup..."

  # Example: Generate Prisma client
  cd apps/api && npx prisma generate

  # Example: Warm up cache
  node scripts/warm-cache.js

  return 0
}

# Called before servers start
pre_start() {
  echo "Pre-start checks..."
  # Add health checks, etc.
  return 0
}
```

**In hatch.conf:**
```bash
HOOKS_FILE="hatch.hooks.sh"
```

---

## Final Output

Generate a complete `hatch.conf` file combining all information gathered.

**Structure:**
```bash
#!/usr/bin/env bash

# Project Configuration
PROJECT_NAME="project-name"
PACKAGE_MANAGER="yarn"

# Docker Services
DOCKER_SERVICES="
  postgres:5432
  redis:6379
"
DOCKER_EXTRAS="mailhog:8025,1025"

# Development Servers
DEV_SERVERS="
  web:apps/web:dev --port {PORT}:10
  api:apps/api:dev --port {PORT}:11
"

# Port Templates
PORT_TEMPLATES="
  .env.local:NEXT_PUBLIC_API_URL=http://localhost:{PORT_api}
"

# MCP Servers
MCP_SERVERS="
  my-server:npx:tsx mcp/host/src/index.ts
"
MCP_ENV="
  my-server:API_URL=http://localhost:{PORT_api}
  my-server:ENVIRONMENT=local
"

# Database Migrations
MIGRATE_TOOL="prisma"

# Database Credentials
DB_USER="myapp"
DB_PASS="secret"
DB_NAME="myapp_dev"

# Setup Steps
SETUP_STEPS="docker:up migrate:execute"

# Hooks
HOOKS_FILE="hatch.hooks.sh"
```

**IMPORTANT:** All multi-value fields use **strings** (not bash arrays). Values are space/newline-separated and parsed by hatch internally.

**Validation checklist:**
- [ ] `PROJECT_NAME` is set
- [ ] `PACKAGE_MANAGER` matches lockfile (or "none")
- [ ] Docker services have ports
- [ ] Dev servers have `{PORT}` placeholder
- [ ] Port offsets are unique and ≥10
- [ ] Migration tool is valid or "none"
- [ ] Setup steps are in logical order
- [ ] MCP env vars use `{PORT_servicename}` for any localhost URLs
- [ ] DEV_SERVERS commands that delegate to package.json scripts do not duplicate flags already in the script (read the target `scripts.dev` entry first)

**If uncertain about any value, add a comment:**
```bash
# TODO: Verify this migration command
MIGRATE_EXECUTE_CMD="npm run migrate"
```

---

## Tips for AI Agents

1. **Read before writing**: Always scan the project structure before making assumptions
2. **Check multiple files**: Don't rely on a single source of truth
3. **Use defaults wisely**: If something isn't found, use sensible defaults and comment them
4. **Port conflicts**: Ensure no two services use the same port offset
5. **Test your output**: The generated config should be syntactically valid bash
6. **Be explicit**: Comment anything that requires manual verification
7. **Check package.json scripts for existing flags**: When DEV_SERVERS uses a package manager workspace command (e.g., `yarn workspace @scope/pkg dev`), read the target package's `scripts.dev` entry. Only add flags in hatch.conf that aren't already in the script. Duplicating flags like `--env` causes CLI tools to fail.

When complete, output the full `hatch.conf` file.
