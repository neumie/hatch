#!/usr/bin/env bash
# update.sh - Self-update hatch

_header "Hatch Update"

# Check if HATCH_HOME is a git repo
if [[ -d "$HATCH_HOME/.git" ]]; then
  _info "Updating from git repository"
  
  # Show current version
  if [[ -f "$HATCH_HOME/VERSION" ]]; then
    CURRENT_VERSION=$(cat "$HATCH_HOME/VERSION")
    _info "Current version: $CURRENT_VERSION"
  fi
  
  # Pull latest (use git -C to avoid changing working directory)
  git -C "$HATCH_HOME" pull || _die "Failed to pull updates"
  
  # Show new version
  if [[ -f "$HATCH_HOME/VERSION" ]]; then
    NEW_VERSION=$(cat "$HATCH_HOME/VERSION")
    _success "Updated to version: $NEW_VERSION"
  else
    _success "Updated to latest commit"
  fi
else
  _warn "HATCH_HOME is not a git repository"
  _info "To enable updates, clone from git:"
  echo "  git clone <repository-url> ~/.hatch"
  exit 1
fi
