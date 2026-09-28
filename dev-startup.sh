#!/bin/bash
# Start the service locally for development on macOS.
#
#   ./dev-startup.sh
#
# Exports service.conf values as environment variables (the uid/gid only
# matter on the production VM where NFS root_squash is in play) and runs
# docker compose.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$REPO_DIR/service.conf"

if [ ! -f "$CONF_FILE" ]; then
    echo "FATAL: $CONF_FILE not found." >&2
    exit 1
fi
# shellcheck source=service.conf
source "$CONF_FILE"

export SVC_USER="$SVC_USER"
export SVC_UID="$(id -u)"
export SVC_GID="$(id -g)"
export SVC_FQDN=localhost

docker compose up -d --build
echo
echo "Running at http://localhost:8080/"
echo "Stop with: docker compose down"
