#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

missing_pid_state_sweeps_workspace() (
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"

  # Dynamic test root; sourced file is checked separately.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  local sweeps=0
  _warn() { :; }
  _success() { :; }
  _sweep_workspace_processes() { sweeps=$((sweeps + 1)); }

  hatch_stop_servers
  [[ "$sweeps" -eq 1 ]] || fail "expected one fallback sweep, got $sweeps"
)

stop_signals_only_the_owned_pid_tree() (
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch service
  echo "web:4242:3000:service" > .hatch/pids

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  local kill_log="$tmp/kill.log"
  _header() { :; }
  _info() { :; }
  _success() { :; }
  _warn() { :; }
  _pid_is_hatch_owned() { return 0; }
  _check_port() { return 1; }
  _sweep_workspace_processes() { :; }
  sleep() { :; }
  pgrep() { return 1; }
  kill() {
    if [[ "$1" == "-0" ]]; then
      return 0
    fi
    echo "$*" >> "$kill_log"
    return 0
  }

  hatch_stop_servers
  if grep -Eq '^-(TERM|KILL|9) -[0-9]+' "$kill_log"; then
    fail "stop attempted to signal an unowned process group"
  fi
  grep -qx -- '-TERM 4242' "$kill_log" || fail "owned PID did not receive SIGTERM"
  grep -qx -- '-9 4242' "$kill_log" || fail "owned PID did not receive force-kill fallback"
)

stale_pid_metadata_is_not_signalled() (
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch service
  echo "web:4242:3000:service" > .hatch/pids

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  local kill_log="$tmp/kill.log"
  _header() { :; }
  _info() { :; }
  _success() { :; }
  _warn() { :; }
  _pid_is_hatch_owned() { return 1; }
  _check_port() { return 1; }
  _sweep_workspace_processes() { :; }
  kill() {
    if [[ "$1" == "-0" ]]; then
      return 0
    fi
    echo "$*" >> "$kill_log"
    return 0
  }

  hatch_stop_servers
  [[ ! -s "$kill_log" ]] || fail "stale PID metadata signalled an unrelated process"
)

stale_port_listener_is_not_signalled() (
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  local kills=0
  lsof() { echo "777"; }
  _pid_holds_owner_file() { return 1; }
  _kill_tree() { kills=$((kills + 1)); }
  _warn() { :; }

  _force_free_port 3000
  [[ "$kills" -eq 0 ]] || fail "stale port record killed an unowned listener"
)

ownership_check_matches_only_the_inherited_descriptor() (
  local tmp owned_pid unowned_pid
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch
  : > .hatch/owner

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  sleep 30 9<.hatch/owner &
  owned_pid=$!
  sleep 30 &
  unowned_pid=$!

  _pid_is_hatch_owned "$owned_pid" || fail "inherited ownership descriptor was rejected"
  if _pid_is_hatch_owned "$unowned_pid"; then
    fail "process without ownership descriptor was accepted"
  fi
  kill "$owned_pid" "$unowned_pid" 2>/dev/null || true
  wait "$owned_pid" "$unowned_pid" 2>/dev/null || true
)

workspace_sweep_reaps_an_owned_anchor_and_its_child() (
  local tmp anchor_pid child_pid
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch
  : > .hatch/owner

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  sh -c 'sleep 30 & echo $! > child.pid; wait' 9<.hatch/owner &
  anchor_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f child.pid ]] && break
    sleep 0.05
  done
  child_pid=$(cat child.pid)

  hatch_sweep_orphans
  wait "$anchor_pid" 2>/dev/null || true
  local anchor_alive=0 child_alive=0
  kill -0 "$anchor_pid" 2>/dev/null && anchor_alive=1
  kill -0 "$child_pid" 2>/dev/null && child_alive=1
  if [[ $anchor_alive -eq 1 || $child_alive -eq 1 ]]; then
    kill -KILL "$anchor_pid" "$child_pid" 2>/dev/null || true
    fail "workspace sweep left an owned anchor or child alive"
  fi
)

service_sweep_preserves_other_services() (
  local tmp first_pid second_pid
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch/owners
  : > .hatch/owners/first
  : > .hatch/owners/second

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  sleep 30 9<.hatch/owners/first &
  first_pid=$!
  sleep 30 9<.hatch/owners/second &
  second_pid=$!

  _sweep_owner_file "$PWD/.hatch/owners/first"
  wait "$first_pid" 2>/dev/null || true
  if kill -0 "$first_pid" 2>/dev/null; then
    kill -KILL "$first_pid" "$second_pid" 2>/dev/null || true
    fail "targeted service sweep left its process alive"
  fi
  if ! kill -0 "$second_pid" 2>/dev/null; then
    fail "targeted service sweep killed another service"
  fi
  kill "$second_pid" 2>/dev/null || true
  wait "$second_pid" 2>/dev/null || true
)

targeted_stale_metadata_cannot_kill_a_sibling_service() (
  local tmp sibling_pid
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cd "$tmp"
  mkdir -p .hatch/owners
  : > .hatch/owner
  : > .hatch/owners/target
  : > .hatch/owners/sibling
  sleep 30 8<.hatch/owner 9<.hatch/owners/sibling &
  sibling_pid=$!
  echo "target:$sibling_pid:3000:service" > .hatch/pids

  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/process.sh"
  _info() { :; }
  _warn() { :; }
  _success() { :; }
  _check_port() { return 0; }
  lsof() {
    case "$*" in
      *"-iTCP:3000"*) echo "$sibling_pid" ;;
      *) command lsof "$@" ;;
    esac
  }

  _stop_targeted_servers target
  if ! kill -0 "$sibling_pid" 2>/dev/null; then
    fail "stale targeted PID/port metadata killed a sibling service"
  fi
  kill "$sibling_pid" 2>/dev/null || true
  wait "$sibling_pid" 2>/dev/null || true
)

missing_pid_state_sweeps_workspace
stop_signals_only_the_owned_pid_tree
stale_pid_metadata_is_not_signalled
stale_port_listener_is_not_signalled
ownership_check_matches_only_the_inherited_descriptor
workspace_sweep_reaps_an_owned_anchor_and_its_child
service_sweep_preserves_other_services
targeted_stale_metadata_cannot_kill_a_sibling_service
echo "process cleanup tests passed"
