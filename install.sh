#!/bin/bash
# Hatch installer
# Usage: curl -fsSL https://raw.githubusercontent.com/{org}/hatch/main/install.sh | bash

set -euo pipefail

HATCH_HOME="${HATCH_HOME:-$HOME/.hatch}"
REPO_URL="${HATCH_REPO:-https://github.com/{org}/hatch.git}"

_info() { printf '\033[34m[info]\033[0m %s\n' "$1"; }
_ok()   { printf '\033[32m[ok]\033[0m   %s\n' "$1"; }
_err()  { printf '\033[31m[error]\033[0m %s\n' "$1" >&2; }
_die()  { _err "$1"; exit 1; }

# Check prerequisites
command -v git >/dev/null 2>&1 || _die "git is required. Install it first."

# Install or update
if [ -d "$HATCH_HOME/.git" ]; then
  _info "Updating existing installation..."
  git -C "$HATCH_HOME" pull --quiet
  _ok "Updated to $(cat "$HATCH_HOME/VERSION" 2>/dev/null || echo 'unknown')"
else
  if [ -d "$HATCH_HOME" ]; then
    _info "Existing directory found at $HATCH_HOME, backing up..."
    mv "$HATCH_HOME" "$HATCH_HOME.backup.$(date +%s)"
  fi
  _info "Installing hatch to $HATCH_HOME..."
  git clone --quiet "$REPO_URL" "$HATCH_HOME"
  _ok "Installed version $(cat "$HATCH_HOME/VERSION" 2>/dev/null || echo 'unknown')"
fi

# Create data directories
mkdir -p "$HATCH_HOME/secrets"
mkdir -p "$HATCH_HOME/data"
mkdir -p "$HATCH_HOME/projects"

# Make entry point executable
chmod +x "$HATCH_HOME/bin/hatch"

# Add to PATH
HATCH_BIN="$HATCH_HOME/bin"
PATH_LINE="export PATH=\"$HATCH_BIN:\$PATH\""

add_to_path() {
  local rcfile="$1"
  if [ -f "$rcfile" ]; then
    if ! grep -q "hatch/bin" "$rcfile" 2>/dev/null; then
      echo "" >> "$rcfile"
      echo "# hatch - local dev environment tool" >> "$rcfile"
      echo "$PATH_LINE" >> "$rcfile"
      _ok "Added to PATH in $rcfile"
      return 0
    else
      _info "Already in PATH ($rcfile)"
      return 0
    fi
  fi
  return 1
}

# Try shell config files
PATH_ADDED=false
if [ -n "${ZSH_VERSION:-}" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; then
  add_to_path "$HOME/.zshrc" && PATH_ADDED=true
elif [ "$(basename "${SHELL:-}")" = "bash" ]; then
  add_to_path "$HOME/.bashrc" && PATH_ADDED=true
fi

# Fallback: try both
if [ "$PATH_ADDED" = "false" ]; then
  add_to_path "$HOME/.zshrc" || add_to_path "$HOME/.bashrc" || add_to_path "$HOME/.profile" || true
fi

echo ""
echo "Hatch installed successfully!"
echo ""
echo "To start using hatch, either:"
echo "  1. Open a new terminal"
echo "  2. Run: export PATH=\"$HATCH_BIN:\$PATH\""
echo ""
echo "Then in any project directory:"
echo "  hatch init     # Generate config for your project"
echo "  hatch setup    # Set up the dev environment"
echo "  hatch run      # Start dev servers"
echo ""
echo "Run 'hatch help' for all commands."
