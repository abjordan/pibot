# Read-only status viewer for pibot agent containers.
#
# Deliberately a separate image from the agent: it holds no credentials, sits on
# its own network, and mounts the config volumes read-only. The only reason pi
# is installed here at all is `pi --export`, which renders a session JSONL to
# standalone HTML without touching a provider (it is handled before any model or
# API-key resolution). Build with PIBOT_STATUS_EXPORT=0 wired in the compose
# environment if you would rather not ship it.
FROM node:22-bookworm-slim

ARG PI_VERSION=latest

# Same package and flags as the agent image: no lifecycle scripts needed.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && npm cache clean --force

COPY server.mjs app.html /opt/pibot-status/

# HOME is set to a tmpfs by compose; these keep `pi --export` from attempting
# any startup network call, since this container has no reason to reach out.
ENV NODE_ENV=production \
    PI_OFFLINE=1 \
    PI_SKIP_VERSION_CHECK=1 \
    PI_TELEMETRY=0

EXPOSE 8787

# Runs as an unprivileged uid supplied by compose (`user:`), not as root.
# Session files are world-readable, so no uid match with the agent is required.
CMD ["node", "/opt/pibot-status/server.mjs"]
