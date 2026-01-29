#!/usr/bin/env bash
# stop.sh - Stop all services (dev servers + Docker)

source "$HATCH_LIB/process.sh"
source "$HATCH_LIB/docker.sh"

# Stop dev servers first (if any running)
hatch_stop_servers

# Stop Docker services
hatch_docker_down
