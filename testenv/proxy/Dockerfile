# Ported from AirSCP 1.4.0 testenv/proxy/Dockerfile.
# AirSQL lab "proxy": tinyproxy, an HTTP proxy that wants user airsql / password airsql-proxy (Basic) and only
# CONNECTs to port 22 (the bastion and the jump host) and 3306 (the inner network's databases), by service name.
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache tinyproxy

COPY <<'EOF' /etc/tinyproxy/tinyproxy.conf
User tinyproxy
Group tinyproxy
Port 8888
Timeout 600
LogLevel Info
MaxClients 100
# Docker's networks: connections from the Mac arrive from a gateway address in one of them.
Allow 127.0.0.1
Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16
BasicAuth airsql airsql-proxy
ConnectPort 22
ConnectPort 3306
DisableViaHeader Yes
EOF

EXPOSE 8888
CMD ["tinyproxy", "-d", "-c", "/etc/tinyproxy/tinyproxy.conf"]
