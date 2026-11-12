#!/bin/bash
# Removes AirSQL's MongoDB lab (Compose project airsql-mongo-lab) and nothing else: its containers and their data.
# airsql-lab, whose network it joins, stays; so do the certificates and keyfile in testenv/.certs.
set -euo pipefail
cd "$(dirname "$0")"
docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker
"$docker" compose down --remove-orphans --volumes
