FROM alpine:3.20

# autossh restarts the tunnel if the connection drops.
RUN apk add --no-cache openssh-client autossh

RUN adduser -D -u 1000 tunnel
USER tunnel

# SSH_TARGET is validated here rather than in docker-compose.yml: compose
# interpolates the whole file before applying profiles, so a required check
# there would fail every agent run too. This guard fires only when the tunnel
# container actually starts.
ENTRYPOINT ["/bin/sh", "-c", ": \"${SSH_TARGET:?set SSH_TARGET in .env, e.g. me@gpu-box}\"; exec autossh -M 0 -N \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -L 0.0.0.0:${TUNNEL_PORT}:${SSH_REMOTE} \
    ${SSH_TARGET}"]
