# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hatch is a workspace-isolated development environment manager for full-stack applications. It automates local dev setup: dependency installation, Docker orchestration, port allocation, database migrations, secret injection, and MCP configuration. Written entirely in Bash (3.2+ compatible), targeting macOS (Darwin) and Linux.

## Architecture

**Entry point**: `bin/hatch` — resolves HATCH_HOME, sources `lib/core.sh`, dispatches commands to `cmd/*.sh` via case statement.

**Library layer** (`lib/`):
- `core.sh` — platform abstraction (sed -i, MD5, port checks, URL open), colored logging, utility functions
- `manifest.sh` — loads and validates `hatch.conf` project configuration; searches `.hatch/hatch.conf`, `./hatch.conf`, then `~/.config/hatch/projects/`
- `ports.sh` — dynamic port allocation with cross-workspace coordination via `~/.config/hatch/port-registry` (uses mkdir-based file locking for atomic updates)
- `docker.sh` — generates `docker-compose.override.yaml` with resolved ports, manages containers
- `process.sh` — daemonized dev server management (survives parent shell exit), PID tracking in `.hatch/pids`
- `migrate.sh` — dispatches to migration tools (Prisma, Contember, Knex, Drizzle, custom)
- `secrets.sh` — writes static secrets and injects `{PORT_*}` placeholders into env files
- `mcp.sh` — generates workspace-scoped MCP server config in `~/.claude.json`
- `data.sh` — data import/export with versioning

**Command layer** (`cmd/`): Each command is a standalone script sourced by `bin/hatch`. Key commands: `setup.sh` (full orchestration), `init.sh` (generate hatch.conf), `seed.sh` (populate shared secrets), `up.sh` / `stop.sh` / `down.sh` (dev server lifecycle), `status.sh`, `db.sh`, `migrate.sh`, `doctor.sh`.

**Configuration**: Projects define a `hatch.conf` file (bash-sourced) with multi-value string fields parsed internally. See `examples/acme-app/hatch.conf` for the full schema.

**Port system**: Base port per workspace (default 1481) + unique offsets. Docker services use offsets 0-9, dev servers use 10+. Total spacing: 20 ports per workspace. Port registry at `~/.config/hatch/port-registry` prevents cross-workspace conflicts using tab-separated records.

**Hooks system**: Optional `hatch.hooks.sh` file provides custom setup steps (referenced as `custom:function_name` in SETUP_STEPS) and lifecycle hooks like `post_setup()`.

## Key Conventions

- All multi-value config fields are **newline/space-separated strings**, not bash arrays — parsed by `_parse_services`
- `{PORT}` and `{PORT_servicename}` are placeholder tokens resolved at setup time; `{DOCKER_HOST}` resolves per platform
- Dev server commands in `DEV_SERVERS` must **never** be prefixed with the package manager — `lib/process.sh` prepends it automatically via `_pkg_run`
- Port templates (`PORT_TEMPLATES`) must only target `.gitignore`d files (`.env.local`, `.dev.vars`) — never tracked files or structured configs like `wrangler.toml`
- Platform-specific operations use wrapper functions in `core.sh` (e.g., `_sed_i`, `_md5`, `_is_port_open`, `_open_url`, `_docker_host`)
- ShellCheck directives are used inline for static analysis
- All scripts use `set -euo pipefail`

## No Build/Test/Lint

This is a pure bash tool with no build step, test runner, or linter configuration. Changes are validated manually and via ShellCheck. The install process clones the repo to `~/.hatch` and symlinks `bin/hatch` to PATH.

## Key Directories

- `HATCH_HOME`: `~/.hatch` (repo installation)
- `HATCH_CONFIG`: `~/.config/hatch` (user data root)
- `HATCH_SECRETS`: `~/.config/hatch/secrets/` (shared secrets per project)
- `HATCH_DATA`: `~/.config/hatch/data/` (data exports per project)
- `HATCH_PROJECTS`: `~/.config/hatch/projects/` (user project configs)
