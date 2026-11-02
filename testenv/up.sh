#!/bin/bash
# Starts AirSQL's Docker test lab (docker-compose.yml, Compose project airsql-lab) on 127.0.0.1 only, or only the
# services named (testenv/up.sh mysql84 bastion secure), with what they depend on. Makes the throwaway SSH key
# (testenv/.keys) and the lab's certificate authority (testenv/.certs) first. Safe to run again: it builds what
# changed, starts what isn't running and waits until every server is healthy and every published port answers.
# testenv/down.sh removes the lab; testenv/AGENT.md says how to use it.
set -euo pipefail
cd "$(dirname "$0")"

# Docker Desktop's own command line tool, else the one on PATH.
docker=/Applications/Docker.app/Contents/Resources/bin/docker
[[ -x $docker ]] || docker=docker

# The lab key: the bastion and the jump host take it as well as their passwords.
mkdir -p .keys
chmod 700 .keys
[[ -f .keys/id_lab ]] || /usr/bin/ssh-keygen -q -t ed25519 -N '' -C airsql-lab -f .keys/id_lab

# The lab CA and its certificates. secure.pem names the server "secure", the name its clients use through the bastion
# or a proxy (no localhost or 127.0.0.1: TLS must be checked against that name, not the local end of a tunnel);
# wrongname.pem names another server; client.pem is for the x509 login. Server certificates last 800 days (macOS
# takes at most 825). Made again when one is missing or expires within a week; the two servers that use them are then
# made again too, as they read them when they start.
mkdir -p .certs
chmod 700 .certs
openssl=/usr/bin/openssl
current() {
    local name
    for name in ca secure wrongname client; do
        "$openssl" x509 -checkend 604800 -noout -in ".certs/$name.pem" >/dev/null 2>&1 || return 1
    done
}
certificate() {  # file name, common name, extensions
    "$openssl" req -new -newkey rsa:2048 -nodes -subj "/CN=$2" -keyout ".certs/$1-key.pem" -out ".certs/$1.csr" 2>/dev/null
    "$openssl" x509 -req -sha256 -days 800 -in ".certs/$1.csr" -CA .certs/ca.pem -CAkey .certs/ca-key.pem \
        -set_serial "0x$("$openssl" rand -hex 8)" -extfile <(printf '%b\n' "$3") -out ".certs/$1.pem" 2>/dev/null
    rm ".certs/$1.csr"
}
if ! current; then
    echo "Making the lab's certificate authority and certificates (testenv/.certs)..."
    "$openssl" req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 3650 -subj '/CN=AirSQL lab CA' \
        -config <(printf '%b\n' '[req]\ndistinguished_name = dn\nx509_extensions = ca\n[dn]\n[ca]' \
            'basicConstraints = critical, CA:TRUE\nkeyUsage = critical, keyCertSign, cRLSign\nsubjectKeyIdentifier = hash') \
        -keyout .certs/ca-key.pem -out .certs/ca.pem 2>/dev/null
    server='basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature, keyEncipherment\nextendedKeyUsage = serverAuth'
    certificate secure secure "$server\nsubjectAltName = DNS:secure"
    certificate wrongname elsewhere.invalid "$server\nsubjectAltName = DNS:elsewhere.invalid"
    certificate client airsql-lab-client 'basicConstraints = CA:FALSE\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = clientAuth'
    "$docker" compose rm --force --stop --volumes secure wrongname >/dev/null 2>&1 || true
fi

# Three services at a time: a server takes memory for a minute while it seeds, and all of them at once need more than
# Docker's VM may have.
services=("$@")
(( ${#services[@]} )) || services=($("$docker" compose config --services))
echo "Starting AirSQL's test lab (a server's first start pulls, builds and seeds it: minutes, not seconds)..."
for (( i = 0; i < ${#services[@]}; i += 3 )); do
    "$docker" compose up --detach --build --quiet-build --quiet-pull --remove-orphans --wait --wait-timeout 1200 \
        "${services[@]:i:3}"
done

# Docker Desktop forwards the published ports from the Mac: each answers. The servers send their greeting, the bastion
# its banner, the HTTP proxies a reply to CONNECT (407: no login given) and the SOCKS proxy one to its greeting.
answers() {
    local reply=""
    exec 3<>"/dev/tcp/127.0.0.1/$1" || return 1
    case $1 in
        44310) printf '\005\001\002' >&3 ;;
        44328 | 44329) printf 'CONNECT secure:3306 HTTP/1.0\r\n\r\n' >&3 ;;
    esac
    IFS= read -r -t 5 -n 1 reply <&3 || true
    exec 3<&-
    [[ -n $reply ]]
}
for port in $("$docker" compose ps --format '{{range .Publishers}}{{if .PublishedPort}}{{.PublishedPort}} {{end}}{{end}}'); do
    tries=0
    until answers "$port" 2>/dev/null; do
        if (( ++tries == 30 )); then
            echo "Nothing answers on 127.0.0.1:$port. See: $docker compose -f $PWD/docker-compose.yml logs" >&2
            exit 1
        fi
        sleep 1
    done
done

if (( $# )); then
    echo "Up: $* (and what they depend on). The whole lab: testenv/up.sh. Logins and routes: testenv/AGENT.md."
    exit 0
fi
cat <<'EOF'
AirSQL's test lab is up (Compose project airsql-lab), on 127.0.0.1 only. Logins and routes: testenv/AGENT.md.
  MySQL    5.7 :44357   8.0 :44380   8.4 :44384   9.7 :44397
  MariaDB 10.5 :44305  10.6 :44306  10.11 :44311  11.4 :44314  11.8 :44318
  many     :44350  MariaDB 11.4 with 5,000 tables (database many_tables)
  proxysql :44333  ProxySQL in front of mariadb114   slow :44340  mysql84, about 100 ms more per round trip
  bastion  :44322  SSH, bastion / airsql-bastion or the key testenv/.keys/id_lab; behind it secure:3306,
                   wrongname:3306 and jump:22 (jump / airsql-jump), and behind that deep:3306
  proxy :44328 (HTTP, Basic)  digestproxy :44329 (HTTP, Digest)  socksproxy :44310 (SOCKS5): airsql / airsql-proxy
  Databases: root / airsql-root, airsql / airsql-pass (everything), reader / reader-pass; fixture, read-only
Lab tests: AIRSQL_LAB=1 ./test.sh    Remove the lab: testenv/down.sh
EOF
