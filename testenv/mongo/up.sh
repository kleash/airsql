#!/bin/bash
# Starts AirSQL's MongoDB lab (docker-compose.yml here, Compose project airsql-mongo-lab) once airsql-lab's hops run:
# makes the members' certificates from the lab CA and their keyfile (testenv/.certs), starts the servers, and the first
# time initiates the replica set rs0 and seeds it (seed/). Safe to run again. testenv/mongo/down.sh removes it.
set -euo pipefail
cd "$(dirname "$0")"

if common=$(git rev-parse --git-common-dir 2>/dev/null) && [[ ! $common/.. -ef ../.. ]]; then
    echo "Only the main checkout starts the lab: $(cd "$common/.." && pwd)/testenv/mongo/up.sh" >&2
    exit 1
fi
docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker

# airsql-lab's network and hops come first; its up.sh also makes the CA.
hops=(bastion jump proxy digestproxy socksproxy)
running=$("$docker" compose -f ../docker-compose.yml ps --services --status running 2>/dev/null || true)
for hop in "${hops[@]}"; do
    grep -qx "$hop" <<< "$running" || ../up.sh "${hops[@]}"
done

# Each member's certificate names it alone (TLS is checked against the member's name); serverAuth and clientAuth, as
# members also connect to each other with it. Made again when missing, expiring within a week, or not from this CA.
certs=../.certs
openssl=/usr/bin/openssl
for member in mongo-rs1 mongo-rs2 mongo-rs3; do
    if "$openssl" x509 -checkend 604800 -noout -in "$certs/$member.pem" >/dev/null 2>&1 &&
        "$openssl" verify -CAfile "$certs/ca.pem" "$certs/$member.pem" >/dev/null 2>&1; then
        continue
    fi
    "$openssl" req -new -newkey rsa:2048 -nodes -subj "/CN=$member" -keyout "$certs/$member-key.pem" \
        -out "$certs/$member.csr" 2>/dev/null
    "$openssl" x509 -req -sha256 -days 800 -in "$certs/$member.csr" -CA "$certs/ca.pem" -CAkey "$certs/ca-key.pem" \
        -set_serial "0x$("$openssl" rand -hex 8)" -out "$certs/$member.pem" -extfile <(printf '%b\n' \
        'basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment' \
        "extendedKeyUsage = serverAuth, clientAuth\nsubjectAltName = DNS:$member") 2>/dev/null
    rm "$certs/$member.csr"
    "$docker" compose rm --force --stop "$member" >/dev/null 2>&1 || true
done
[[ -f $certs/mongo-keyfile ]] || "$openssl" rand -base64 756 > "$certs/mongo-keyfile"

echo "Starting AirSQL's MongoDB lab..."
before=$("$docker" compose ps --all --quiet | sort)
"$docker" compose up --detach --quiet-pull --remove-orphans
# The proxies keep the addresses they looked up, and a server made again may have another one (or an old one of another
# member): they start again too.
[[ $before == "$("$docker" compose ps --all --quiet | sort)" ]] ||
    "$docker" compose -f ../docker-compose.yml restart proxy digestproxy socksproxy >/dev/null

# mongosh on a server: the replica set over TLS on localhost (its certificate names the member, hence the one
# exception here), which also lets the first login be made there.
shell() {
    local service=$1; shift
    if [[ $service == mongo-solo ]]; then
        "$docker" compose exec -T "$service" mongosh --quiet "$@"
    else
        "$docker" compose exec -T "$service" mongosh --quiet --tls --tlsCAFile /tls/ca.pem --tlsAllowInvalidHostnames "$@"
    fi
}
for service in mongo-solo mongo-rs1 mongo-rs2 mongo-rs3; do
    tries=0
    until shell "$service" --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; do
        (( ++tries < 120 )) || { echo "$service doesn't answer: $docker compose -f $PWD/docker-compose.yml logs $service" >&2; exit 1; }
        sleep 1
    done
done

root=(-u root -p airsql-root --authenticationDatabase admin)
if ! shell mongo-rs1 "${root[@]}" --eval 'rs.status().ok' >/dev/null 2>&1; then
    echo "Initiating the replica set rs0 and seeding it..."
    shell mongo-rs1 --eval 'try { rs.status() } catch (e) { rs.initiate({_id: "rs0", members: [
        {_id: 0, host: "mongo-rs1:27017", priority: 2}, {_id: 1, host: "mongo-rs2:27017"}, {_id: 2, host: "mongo-rs3:27017"}]}) }' >/dev/null
    tries=0
    until [[ $(shell mongo-rs1 --eval 'db.hello().isWritablePrimary' 2>/dev/null) == true ]]; do
        (( ++tries < 120 )) || { echo "mongo-rs1 didn't become primary" >&2; exit 1; }
        sleep 1
    done
    shell mongo-rs1 --eval 'db.getSiblingDB("admin").createUser({user: "root", pwd: "airsql-root", roles: ["root"]})' >/dev/null
    "$docker" compose exec -T mongo-rs1 mongosh --quiet --tls --tlsCAFile /tls/ca.pem --tlsAllowInvalidHostnames \
        "${root[@]}" fixture < seed/fixture.js >/dev/null
fi
echo "AirSQL's MongoDB lab is up (Compose project airsql-mongo-lab). Logins and routes: testenv/AGENT.md."
