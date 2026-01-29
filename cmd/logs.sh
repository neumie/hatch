#!/usr/bin/env bash
# logs.sh - View Docker service logs

# If no args, show all logs
# Otherwise, pass service names to docker compose logs
if [[ $# -eq 0 ]]; then
  exec docker compose logs -f
else
  exec docker compose logs -f "$@"
fi
