#!/usr/bin/env bash
# migrate.sh - Migration tool dispatch
# Depends on: core.sh, manifest.sh

# hatch_migrate SUBCOMMAND [args...]
# SUBCOMMAND is: execute, execute_until, diff, status, amend
# Reads MIGRATE_TOOL from manifest and dispatches to appropriate tool
hatch_migrate() {
  local subcommand="${1:-}"
  shift || true

  if [[ -z "$subcommand" ]]; then
    _die "Usage: hatch_migrate {execute|execute_until|diff|status|amend} [args...]"
  fi

  if [[ -z "${MIGRATE_TOOL:-}" ]]; then
    _die "No migration tool configured. Set MIGRATE_TOOL in hatch.conf"
  fi

  case "$MIGRATE_TOOL" in
    contember)
      case "$subcommand" in
        execute)
          _info "Executing Contember migrations"
          _pkg_run contember migrations:execute --yes
          ;;
        execute_until)
          _info "Executing Contember migrations until: $1"
          _pkg_run contember migrations:execute --yes --until "$1"
          ;;
        diff)
          _info "Creating Contember migration diff"
          _pkg_run contember migrations:diff "$@"
          ;;
        status)
          _info "Checking Contember migration status"
          _pkg_run contember migrations:status
          ;;
        amend)
          _info "Amending Contember migration"
          _pkg_run contember migrations:amend
          ;;
        *)
          _die "Unknown subcommand for contember: $subcommand"
          ;;
      esac
      ;;

    prisma)
      case "$subcommand" in
        execute)
          _info "Executing Prisma migrations"
          _pkg_run prisma migrate deploy
          ;;
        execute_until)
          _warn "execute_until not supported for prisma; running all migrations"
          _pkg_run prisma migrate deploy
          ;;
        diff)
          _info "Creating Prisma migration"
          _pkg_run prisma migrate dev --name "$@"
          ;;
        status)
          _info "Checking Prisma migration status"
          _pkg_run prisma migrate status
          ;;
        amend)
          _warn "Prisma does not support amend operation"
          return 1
          ;;
        *)
          _die "Unknown subcommand for prisma: $subcommand"
          ;;
      esac
      ;;

    knex)
      case "$subcommand" in
        execute)
          _info "Executing Knex migrations"
          _pkg_run knex migrate:latest
          ;;
        execute_until)
          _warn "execute_until not supported for knex; running all migrations"
          _pkg_run knex migrate:latest
          ;;
        diff)
          _info "Creating Knex migration"
          _pkg_run knex migrate:make "$@"
          ;;
        status)
          _info "Checking Knex migration status"
          _pkg_run knex migrate:status
          ;;
        amend)
          _warn "Knex does not support amend operation"
          return 1
          ;;
        *)
          _die "Unknown subcommand for knex: $subcommand"
          ;;
      esac
      ;;

    drizzle)
      case "$subcommand" in
        execute)
          _info "Executing Drizzle migrations"
          _pkg_run drizzle-kit push
          ;;
        execute_until)
          _warn "execute_until not supported for drizzle; running all migrations"
          _pkg_run drizzle-kit push
          ;;
        diff)
          _info "Creating Drizzle migration"
          _pkg_run drizzle-kit generate --name "$@"
          ;;
        status)
          _info "Checking Drizzle migration status"
          _pkg_run drizzle-kit status
          ;;
        amend)
          _warn "Drizzle does not support amend operation"
          return 1
          ;;
        *)
          _die "Unknown subcommand for drizzle: $subcommand"
          ;;
      esac
      ;;

    custom)
      case "$subcommand" in
        execute)
          if [[ -z "${MIGRATE_CMD_EXECUTE:-}" ]]; then
            _die "MIGRATE_CMD_EXECUTE not set for custom migration tool"
          fi
          _info "Executing custom migration: $MIGRATE_CMD_EXECUTE"
          eval "$MIGRATE_CMD_EXECUTE"
          ;;
        execute_until)
          if [[ -n "${MIGRATE_CMD_EXECUTE_UNTIL:-}" ]]; then
            _info "Executing custom migrations until: $1"
            eval "$MIGRATE_CMD_EXECUTE_UNTIL" "$1"
          else
            _warn "MIGRATE_CMD_EXECUTE_UNTIL not set for custom migration tool; running all migrations"
            if [[ -z "${MIGRATE_CMD_EXECUTE:-}" ]]; then
              _die "MIGRATE_CMD_EXECUTE not set for custom migration tool"
            fi
            eval "$MIGRATE_CMD_EXECUTE"
          fi
          ;;
        diff)
          if [[ -z "${MIGRATE_CMD_DIFF:-}" ]]; then
            _die "MIGRATE_CMD_DIFF not set for custom migration tool"
          fi
          _info "Creating custom migration diff"
          eval "$MIGRATE_CMD_DIFF" "$@"
          ;;
        status)
          if [[ -z "${MIGRATE_CMD_STATUS:-}" ]]; then
            _die "MIGRATE_CMD_STATUS not set for custom migration tool"
          fi
          _info "Checking custom migration status"
          eval "$MIGRATE_CMD_STATUS"
          ;;
        amend)
          if [[ -z "${MIGRATE_CMD_AMEND:-}" ]]; then
            _warn "MIGRATE_CMD_AMEND not set for custom migration tool"
            return 1
          fi
          _info "Amending custom migration"
          eval "$MIGRATE_CMD_AMEND"
          ;;
        *)
          _die "Unknown subcommand for custom: $subcommand"
          ;;
      esac
      ;;

    *)
      _die "Unknown migration tool: $MIGRATE_TOOL"
      ;;
  esac
}
