# Hatch

Hatch is a worktree-native development environment manager for full-stack applications. It gives each git worktree its own isolated dev environment — separate ports, Docker containers, and secrets — so you can run multiple branches simultaneously without conflicts.

## What Hatch Does

Setting up a local dev environment means installing dependencies, starting Docker containers, running database migrations, seeding data, wiring up ports in env files, and launching dev servers. Hatch automates all of this per worktree.

Each worktree gets its own:
- **Port allocation** — unique ports per worktree, no conflicts between branches
- **Docker containers** — namespaced by worktree
- **Secret files** — symlinked from a shared `~/.config/hatch/secrets/` store

On top of that, Hatch handles:
- **Dependency installation** — detects your package manager (npm, yarn, pnpm, bun) and installs
- **Database migrations** — runs migrations using your project's tool (Prisma, Knex, Drizzle, Contember, or custom)
- **Dev server management** — launches and daemonizes dev servers, surviving terminal closure
- **MCP configuration** — generates workspace-scoped MCP server configs for AI coding tools

Hatch is written entirely in Bash (3.2+ compatible) and targets macOS (Darwin) and Linux. Configuration lives in `hatch.conf` and an optional `hatch.hooks.sh` for custom lifecycle logic.

## Installation (once per machine)

```bash
curl -fsSL https://raw.githubusercontent.com/neumie/hatch/main/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/neumie/hatch.git ~/.hatch
ln -sf ~/.hatch/bin/hatch /usr/local/bin/hatch
```

## Project Configuration

### Generate config (once per repo)

In your project root:

```bash
hatch init
```

This creates `hatch.conf` with detected settings. Edit it to match your project — see `hatch.conf.example` for all options.

### Seed secrets

List your secret env files in `hatch.conf` (once per repo, or when secret files are added/removed):

```bash
SECRET_FILES="
  admin/.env.local
  scan/.env.local
  worker/.dev.vars
"
```

Then run `hatch seed` from the main repo whenever secret values change:

```bash
hatch seed
```

This copies those files to `~/.config/hatch/secrets/<project>/`. Every worktree running `hatch setup` will get them via symlinks.

## Per-Worktree Setup

```bash
hatch setup
```

This runs the full orchestration: installs dependencies, starts Docker, links secrets, injects ports, runs migrations, and imports data. Run this in each new worktree.

## Daily Usage

### Start dev servers

```bash
hatch up                  # Start all dev servers
hatch up admin api        # Start specific servers only
```

### Check status

```bash
hatch status              # Show running servers and Docker containers
hatch logs                # View Docker service logs
hatch open admin          # Open a service URL in the browser
```

### Stop (pause)

```bash
hatch stop
```

Kills dev servers and pauses Docker containers. Containers and volumes are preserved — `hatch up` resumes quickly.

### Tear down

```bash
hatch down
```

Kills dev servers, removes Docker containers and volumes, releases allocated ports, and cleans runtime state. Your config, env files, and generated overrides are preserved — `hatch setup` will rebuild everything.

## Hooks

For custom logic during setup, create a `hatch.hooks.sh` file and reference it in `hatch.conf`:

```bash
HOOKS_FILE="hatch.hooks.sh"
```

Hooks let you run arbitrary functions as setup steps via `custom:<function_name>` in `SETUP_STEPS`, or automatically via the `post_setup` lifecycle hook. This is useful for things like data imports, code generation, or project-specific bootstrapping.

```bash
#!/usr/bin/env bash

# Custom setup step — called via "custom:import_content" in SETUP_STEPS
import_content() {
  hatch_import_data
}

# Called automatically after all setup steps complete
post_setup() {
  (cd apps/api && npx prisma generate)
}
```

```bash
SETUP_STEPS="docker:up migrate:execute_until data:import migrate:execute custom:import_content"
```

## Diagnostics

```bash
hatch doctor              # Check system dependencies
hatch help                # Show all commands
```
