# CLAUDE.md

Hatch is a workspace-isolated dev environment manager (Bash 3.2+, macOS/Linux). Automates dep install, Docker orchestration, port allocation, migrations, secret injection, MCP config.

## No build, no tests, no lint

Pure bash. Validate manually with ShellCheck. Never invent `npm test` / `make lint` — none exist.

## Bash / shell rules

- **Bash 3.2 compat.** Never use `declare -A` (associative arrays), `${var,,}` (case mod), `mapfile`/`readarray`, or `[[ -v var ]]`. macOS ships bash 3.2; breakage is silent.
- **All scripts start with `set -euo pipefail`.** With `pipefail`, any command in a pipeline that may legitimately not match (e.g. `grep`) needs `|| true` or the script aborts.
- **Platform & package-manager calls go through wrappers in `lib/core.sh`.** Never call `sed -i`, `md5`/`md5sum`, `lsof`, `open`/`xdg-open`, or `yarn`/`npm`/`pnpm`/`bun` directly. Use `_sed_i`, `_md5`, `_check_port`, `_open_url`, `_docker_host`, `_pkg_run` (reads `PACKAGE_MANAGER`, used by `lib/process.sh` for `DEV_SERVERS`). Differences between macOS and Linux — and between package managers — are silent corruption otherwise.

## Manifest & dispatch contracts

- **Multi-value config fields are newline-separated strings, never bash arrays.** Parse only via `_parse_services VAR_NAME` (in `lib/ports.sh`). It trims whitespace and skips `#` comment lines — re-implementing this parser elsewhere drifts behavior.
- **Dev server commands in `DEV_SERVERS` must not be prefixed with the package manager.** `lib/process.sh` runs them through `_pkg_run` which prepends `yarn`/`npm run`/`pnpm`/`bun`. Adding it yourself double-prefixes.
  - Wrong: `admin:admin:yarn vite --port {PORT}:10`
  - Right: `admin:admin:vite --port {PORT}:10`
- **`PORT_TEMPLATES` only target `.gitignore`d files** (`.env.local`, `.dev.vars`). Never tracked files, never structured configs like `wrangler.toml` — the placeholder substitution is line-based and corrupts TOML/JSON.
- **Cross-workspace port registry edits must hold the lock.** The port registry (`$HATCH_PORT_REGISTRY`) is coordinated via `mkdir`-based locking in `lib/ports.sh` (`_port_registry_lock` / `_port_registry_unlock`). Never write the file directly.
- **Adding a new top-level command means two edits:** create `cmd/<name>.sh` AND add `<name>` to the pipe-separated case glob in `bin/hatch` (single line listing all commands). Otherwise `Unknown command`.
- **Extending `hatch init` means editing the numbered sections in `cmd/init.sh`** (interactive wizard built on `_prompt_value` / `_prompt_multiline` / `_prompt_confirm` / `_prompt_choice`, all of which honor `_INIT_AUTO`). Tool-specific augmentation lives in skill prompts (`commands/hatch-init-*.md`, `prompts/hatch-init-*.md`), not by forking the wizard.
- **Adding a new migration tool means editing the case in `hatch_migrate`** (in `lib/migrate.sh`, dispatched on `MIGRATE_TOOL`). `MIGRATE_TOOL=foo` without a matching branch silently no-ops; current tools are `contember`, `prisma`, `knex`, `drizzle`.
- **Never add new `SETUP_STEPS` prefixes via manifest.** Register the prefix in the `cmd/setup.sh` case dispatcher first; see the dispatcher for the current set of recognized prefixes (today: `docker:up`, `docker:down`, `deps:install`, `migrate:execute`, `migrate:execute_until`, `data:import`, `custom:*`).

## Deep modules — extend, never fork

- **Always extend `lib/detect.sh` for any auto-detection.** Never re-implement detection in `cmd/<name>.sh` or other `lib/*.sh` files — almost every heuristic you'd want already exists. Categories covered: project name (`_detect_project_name`), package manager (`_detect_package_manager`), Docker compose file (`_detect_docker_compose_file`), DB credentials per engine, monorepo + workspace dirs, workspace name, framework, dev-server inference (`_detect_dev_servers`), hooks file (`_detect_hooks_file`), JSON probing without `jq`. Read it before adding a new probe.
- **Placeholder resolution stays in lib.** New placeholder tokens (`{PORT_*}`, `{DOCKER_HOST}`, …): resolve them inside `lib/secrets.sh` (env files), `lib/docker.sh` (compose), or `lib/mcp.sh` (`MCP_ENV`). Never resolve placeholders in command scripts — they should call into `lib/`.
- **New helper function:** if it's platform-abstracting (macOS vs Linux), color/log output, or used by ≥2 lib files, it goes in `lib/core.sh`. Otherwise put it in the domain `lib/<area>.sh` it belongs to.
- **New manifest field:** all-caps, prefixed by feature area (`DOCKER_*`, `MCP_*`, `DATA_*`, `MIGRATE_*`). Add a default in `lib/manifest.sh` if the field is optional.

## Architecture (non-obvious only)

(Reference: `examples/acme-app/hatch.conf` — full manifest schema with every field in use.)

- **`HATCH_HOME` / `HATCH_CONFIG` / `HATCH_SECRETS` / `HATCH_DATA` / `HATCH_PROJECTS` defaults live near the top of `lib/core.sh`.** Override via env var only to isolate tests.
- **Manifest search order** (`lib/manifest.sh`): `./.hatch/hatch.conf` → `./hatch.conf` (legacy) → `$HATCH_PROJECTS/<project>.conf`. Put new project configs in `.hatch/`; never resurrect the legacy root path.
- **Hooks file**: `HOOKS_FILE` defaults to `hatch.hooks.sh`. Both `.sh` and `.ts` work; `_detect_hooks_file` picks one, `_load_ts_hooks` (in `lib/manifest.sh`) generates wrappers that delegate to `lib/ts-hook-runner.ts`. Wire custom setup hooks into `SETUP_STEPS` as `custom:function_name` — direct calls in command scripts won't fire.
- **TS hooks runtime is gated by `PACKAGE_MANAGER`, not by what's installed.** `_load_ts_hooks` picks `bun` if `PACKAGE_MANAGER=bun`, else `npx tsx`. If the chosen runtime is missing, `_load_ts_hooks` calls `_die` — so a misdetected package manager surfaces as a hard failure on first hook load, not a silent skip. If you switch package managers mid-project, re-run detection.
- **Port allocation** (`lib/ports.sh`): `HATCH_PORT_SPACING=20` per workspace. Use offsets 0–9 for Docker services, 10+ for dev servers — never overlap. Non-main workspace base ports are hash-derived with collision probing against the registry AND `_check_port`.
- **Port claiming has two sources of truth.** The registry tracks workspace allocations (other Hatch workspaces); `_check_port` probes the OS for external occupants (other apps, stale Docker containers). Both must succeed before a port is claimed — checking only one lets sibling workspaces collide or non-Hatch processes get stomped.
- **Process management** (`lib/process.sh`): dev servers daemonize and outlive the parent shell. State lives in `.hatch/pids` (colon-separated `name:pid:port:dir`), while every service inherits open fds for `.hatch/owner` and `.hatch/owners/<service>`; cleanup must verify those descriptors with `lsof` before trusting a PID/port, and must not delete/recreate their inodes while services live. `lsof` is therefore a required dependency, not interchangeable with `ss`. `DEV_SERVERS` names must match `[A-Za-z0-9_-]+` — colons in names silently corrupt the pid file. Walk the process tree on stop — never `kill -- -PGID`; sibling workspaces share the group and would die too.
- **MCP servers** split into two manifest fields parsed in `lib/mcp.sh`: `MCP_SERVERS` for local stdio servers, `MCP_REMOTE_SERVERS` for remote URL-based servers with token auth from `mcp/host/.mcp-tokens`. Both parse via `_parse_services`.

## When you discover something

If you hit an undocumented gotcha, a non-obvious convention, or a "compiles but breaks at runtime" failure mode while working on this repo, update this CLAUDE.md. Stale rules are worse than missing rules — fix outdated entries you spot.

