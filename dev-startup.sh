#!/bin/bash
# Start the service locally for development on macOS.
#
#   ./dev-startup.sh
#
# There is no /root/VM.set on a laptop, so this runs the containers as you
# (your own uid/gid) under a placeholder account name. The real service
# account only matters on the production VM, where NFS root_squash is in play;
# there, init.sh reads it from VM.set.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

export SVC_USER=dev-svc
export SVC_UID="$(id -u)"
export SVC_GID="$(id -g)"
export SVC_FQDN=localhost

docker compose up -d --build
echo
echo "Running at http://localhost:8080/"
echo "Stop with: docker compose down"
