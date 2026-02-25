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

  # Install AI commands/rules for detected providers
  if [[ -d "$HATCH_HOME/commands" ]]; then
    # Claude Code
    if [[ -d "$HOME/.claude" ]]; then
      mkdir -p "$HOME/.claude/commands"
      for cmd_file in "$HATCH_HOME"/commands/*.md; do
        [[ -f "$cmd_file" ]] || continue
        ln -sf "$cmd_file" "$HOME/.claude/commands/$(basename "$cmd_file")"
      done
      _success "Installed commands for Claude Code"
    fi

    # Cursor
    if [[ -d "$HOME/.cursor" ]]; then
      mkdir -p "$HOME/.cursor/rules"
      for prompt_file in "$HATCH_HOME"/prompts/*.md; do
        [[ -f "$prompt_file" ]] || continue
        ln -sf "$prompt_file" "$HOME/.cursor/rules/$(basename "$prompt_file")"
      done
      _success "Installed rules for Cursor"
    fi

    # Windsurf
    if [[ -d "$HOME/.windsurf" ]]; then
      mkdir -p "$HOME/.windsurf/rules"
      for prompt_file in "$HATCH_HOME"/prompts/*.md; do
        [[ -f "$prompt_file" ]] || continue
        ln -sf "$prompt_file" "$HOME/.windsurf/rules/$(basename "$prompt_file")"
      done
      _success "Installed rules for Windsurf"
    fi
  fi
else
  _warn "HATCH_HOME is not a git repository"
  _info "To enable updates, clone from git:"
  echo "  git clone <repository-url> ~/.hatch"
  exit 1
fi
