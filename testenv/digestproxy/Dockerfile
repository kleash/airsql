# Ported from AirSCP 1.4.0 testenv/digestproxy/Dockerfile.
# AirSQL lab "digestproxy": squid asking for Digest login only (no Basic), user airsql / password airsql-proxy, and
# only CONNECTs to ports 22 and 3306 (the inner network's SSH hosts and databases, by service name).
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache squid

COPY <<'EOF2' /etc/squid/digest_passwd
airsql:airsql-proxy
EOF2

COPY <<'EOF2' /etc/squid/squid.conf
http_port 8888
# Squid sizes its tables by the descriptor limit, which is huge in a container: 150 MB for nothing.
max_filedescriptors 1024
auth_param digest program /usr/lib/squid/digest_file_auth /etc/squid/digest_passwd
auth_param digest realm airsql-lab
auth_param digest children 2
acl authed proxy_auth REQUIRED
acl lab_ports port 22 3306
acl CONNECT method CONNECT
http_access deny CONNECT !lab_ports
http_access allow CONNECT authed
http_access deny all
cache deny all
access_log none
cache_log /dev/null
pid_filename none
EOF2

EXPOSE 8888
CMD ["squid", "-N", "-f", "/etc/squid/squid.conf"]
