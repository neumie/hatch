# Hatch Setup & Usage Guide

## Initial Setup (once per machine)

### 1. Install Hatch

```bash
curl -fsSL https://raw.githubusercontent.com/neumie/hatch/main/install.sh | bash
```

Or clone manually:

```bash
git clone https://github.com/neumie/hatch.git ~/.hatch
ln -sf ~/.hatch/bin/hatch /usr/local/bin/hatch
```

### 2. Configure your project

In your project root, generate a config:

```bash
hatch init
```

This creates `hatch.conf` with detected settings. Edit it to match your project — see `hatch.conf.example` for all options.

### 3. Seed secrets (once per project)

In the main repo where your secret env files exist (`.env.local`, `.dev.vars`, etc.), list them in `hatch.conf`:

```bash
SECRET_FILES="
  admin/.env.local
  scan/.env.local
  worker/.dev.vars
"
```

Then run:

```bash
hatch seed
```

This copies those files to `~/.hatch/secrets/<project>/`. Every worktree running `hatch setup` will get them via symlinks.

### 4. Set up the workspace

```bash
hatch setup
```

This runs the full orchestration: installs dependencies, starts Docker, links secrets, injects ports, runs migrations, and imports data.

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

### Database

```bash
hatch db shell            # Open psql
hatch db ui               # Open Adminer in browser
hatch db dump             # Dump database to SQL
hatch db restore file.sql # Restore from SQL dump
```

### Migrations

```bash
hatch migrate execute     # Run pending migrations
hatch migrate diff        # Create a new migration
hatch migrate status      # Show migration status
```

### Data

```bash
hatch export              # Export project data to ~/.hatch/data/
hatch seed                # Re-seed secrets from current workspace
```

## Working with Worktrees

Hatch is designed for git worktrees. Each worktree gets its own:
- Port allocation (no conflicts between workspaces)
- Docker containers (namespaced by workspace)
- Secret files (symlinked from shared `~/.hatch/secrets/`)

Typical workflow:

```bash
# In main repo — seed secrets once
hatch seed

# Create a worktree
git worktree add ../my-feature feature-branch

# Set up the worktree
cd ../my-feature
hatch setup
hatch up

# When done
hatch down
```

## Diagnostics

```bash
hatch doctor              # Check system dependencies
hatch help                # Show all commands
```

## Project .gitignore

Add these to your project's `.gitignore`:

```
.hatch/
docker-compose.override.yaml
.env
.env.local
*.dev.vars
```
