# AirSQL lab "slow": a TCP relay (socat) whose interface delays every packet with tc netem; docker-compose.yml gives
# the delay and the server behind it. It needs the NET_ADMIN capability.
FROM alpine:latest@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

RUN apk add --no-cache iproute2-tc socat

EXPOSE 3306
