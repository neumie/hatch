#!/usr/bin/env bash
# seed.sh - Copy secret files to ~/.hatch/secrets for cross-worktree sharing
# Sources: manifest

source "$HATCH_LIB/manifest.sh"
source "$HATCH_LIB/ports.sh"

# Load manifest
PROJECT_NAME=$(hatch_detect_project)
hatch_load_manifest "$PROJECT_NAME"

_header "Seed Secrets"

if [[ -z "${SECRET_FILES:-}" ]]; then
  _die "No SECRET_FILES defined in hatch.conf. Add a list of files to seed."
fi

local_secrets_dir="$HATCH_SECRETS/$PROJECT_NAME"
seed_count=0

while IFS= read -r file_path; do
  [[ -z "$file_path" ]] && continue

  if [[ ! -f "$file_path" ]]; then
    _warn "File not found, skipping: $file_path"
    continue
  fi

  target="$local_secrets_dir/$file_path"
  mkdir -p "$(dirname "$target")"
  cp "$file_path" "$target"
  _info "Seeded: $file_path"
  seed_count=$((seed_count + 1))
done < <(_parse_services SECRET_FILES)

if [[ $seed_count -eq 0 ]]; then
  _warn "No files were seeded"
else
  echo ""
  _success "Seeded $seed_count file(s) to $local_secrets_dir"
fi
