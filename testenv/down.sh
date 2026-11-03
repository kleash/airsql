#!/bin/bash
# Removes AirSQL's Docker test lab (Compose project airsql-lab) and nothing else: its containers, its networks and its
# servers' data (the seed makes it again at the next start). The images stay for a quick next start (--images also
# removes the ones the lab built); so do the key in testenv/.keys and the certificates in testenv/.certs.
set -euo pipefail
cd "$(dirname "$0")"

docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker

case "${1:-}" in
    "") "$docker" compose down --remove-orphans --volumes ;;
    --images) "$docker" compose down --remove-orphans --volumes --rmi local ;;
    *) echo "usage: $0 [--images]" >&2; exit 2 ;;
esac
