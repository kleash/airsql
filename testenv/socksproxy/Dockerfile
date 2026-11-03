# Ported from AirSCP 1.4.0 testenv/socksproxy/Dockerfile.
# AirSQL lab "socksproxy": a SOCKS5 proxy (Dante) that wants user airsql / password airsql-proxy, a system user here,
# and only CONNECTs to ports 22 and 3306 on the inner network, as the HTTP proxies do.
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache dante-server \
 && adduser -D -H -s /sbin/nologin airsql \
 && echo "airsql:airsql-proxy" | chpasswd

COPY <<'EOF2' /etc/sockd.conf
logoutput: stderr
internal: 0.0.0.0 port = 1080
# Out through whichever network leads to the server (the lab's edge and inner networks).
external: eth0
external: eth1
external.rotation: route
socksmethod: username
clientmethod: none
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 port = 22 command: connect }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 port = 3306 command: connect }
EOF2

EXPOSE 1080
CMD ["sockd", "-f", "/etc/sockd.conf"]
