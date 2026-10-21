#!/bin/sh
# Same update pattern as the other stacks on the control-plane servers.
set -e
cd "$(dirname "$0")"
docker compose pull
docker compose down --remove-orphans
docker compose up -d
