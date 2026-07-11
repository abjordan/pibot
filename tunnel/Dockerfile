FROM alpine:3.20

# autossh restarts the tunnel if the connection drops.
RUN apk add --no-cache openssh-client autossh

RUN adduser -D -u 1000 tunnel
USER tunnel

ENTRYPOINT ["/bin/sh", "-c", "exec autossh -M 0 -N \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -L 0.0.0.0:${TUNNEL_PORT}:${SSH_REMOTE} \
    ${SSH_TARGET}"]
