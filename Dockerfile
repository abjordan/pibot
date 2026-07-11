FROM node:22-bookworm-slim

ARG PI_VERSION=latest
ARG USER_UID=1000
ARG USER_GID=1000
# Space-separated pi package sources, e.g.:
#   PI_EXTENSIONS="npm:@juanibiapina/pi-extension-settings npm:@juanibiapina/pi-powerbar"
# Override at build time with --build-arg, or set PI_EXTENSIONS in .env (the
# compose file forwards it). Anything `pi install` accepts works: npm:, git:,
# a bare https:// URL, or a local path copied in earlier in this Dockerfile.
ARG PI_EXTENSIONS=""

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

# Toolchain: python3 + venv, git, ripgrep (pi's grep tool likes it), jq for entrypoint templating.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        python3 \
        python3-dev \
        python3-venv \
        ripgrep \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Debian marks the system python as externally-managed, so `pip install` fails out of the box.
# A venv on PATH means the agent can pip install freely without --break-system-packages.
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir --upgrade pip setuptools wheel
ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:${PATH}"

# Install pi globally as root, then drop privileges at runtime.
# --ignore-scripts is what upstream recommends; pi needs no lifecycle scripts.
RUN npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}" \
    && npm cache clean --force

# The node:* images ship a `node` user at uid 1000, which collides with most hosts' first user.
# Reclaim the id so bind-mounted files come out owned by you, not by root or by `node`.
RUN userdel -r node 2>/dev/null || true; \
    groupadd -g "${USER_GID}" pi 2>/dev/null || true; \
    useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash pi

# Writable by the agent user so it can pip install into the venv mid-session.
RUN chown -R "${USER_UID}:${USER_GID}" /opt/venv

# These three paths are named-volume mountpoints. When Docker first populates an
# empty named volume it copies the image's ownership at that path -- and if the
# path does not exist, it creates it as root, which the unprivileged `pi` user
# then cannot write to. Creating them here, owned by pi, is what makes the
# volumes come up writable.
RUN mkdir -p /home/pi/.pi/agent /home/pi/.npm /home/pi/.cache/pip \
    && chown -R "${USER_UID}:${USER_GID}" /home/pi

# Mountpoint parent for extra skills directories (PI_SKILLS_DIRS, attached by
# the `pi` wrapper as `run -v` flags). It must be a plain image directory: extra
# dirs cannot nest under /opt/pi-skills, which is itself a read-only bind mount.
# Empty here; if nothing is mounted, the entrypoint skips registering it.
RUN mkdir -p /opt/pi-skills.d && chmod 755 /opt/pi-skills.d

# `pi install` writes to $HOME/.pi/agent/{npm/,settings.json} -- and at runtime
# $HOME/.pi is the pi-config *named volume*, which shadows anything baked in
# here. Docker only ever seeds a named volume from the image on its first-ever
# use, so once that volume exists (which it will, after the first run), a
# rebuilt image's extensions would silently stop taking effect.
#
# So: install into a seed location outside /home/pi, owned by pi so a runtime
# merge (see entrypoint.sh) can read it. This makes extensions survive both a
# volume that already existed before this build, and one deleted afterward.
#
# HOME=/opt/pi-seed means `pi install` writes to /opt/pi-seed/.pi/agent -- note
# the .pi component. The trailing tests are a tripwire: if pi's layout ever
# changes, the build fails loudly here rather than producing an image whose
# extensions silently never appear at runtime.
RUN if [ -n "${PI_EXTENSIONS}" ]; then \
        mkdir -p /opt/pi-seed && chown -R "${USER_UID}:${USER_GID}" /opt/pi-seed; \
        for pkg in ${PI_EXTENSIONS}; do \
            echo "installing pi extension: ${pkg}"; \
            su pi -c "HOME=/opt/pi-seed pi install '${pkg}'" || exit 1; \
        done; \
        test -d /opt/pi-seed/.pi/agent/npm \
            || { echo "FATAL: no seed at /opt/pi-seed/.pi/agent/npm -- pi's layout changed" >&2; exit 1; }; \
        test -f /opt/pi-seed/.pi/agent/settings.json \
            || { echo "FATAL: pi install wrote no settings.json" >&2; exit 1; }; \
        echo "--- seeded packages ---"; cat /opt/pi-seed/.pi/agent/settings.json; \
    fi

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Extra system packages. Must run as root, so it sits here rather than at the
# very end -- but still below the npm/extension layers, so changing this list
# doesn't rebuild them, and above the pip layer, so a package like libpq-dev is
# present when psycopg2 builds against it.
#
# The agent cannot apt-install at runtime: it runs unprivileged with all
# capabilities dropped. Baking packages in here is the only way to add them.
#
# Guarded like the pip list -- a bare `apt-get install` is an error. Word
# splitting is intentional; version pins survive it (`curl=7.88.1-10+deb12u5`).
# Unknown packages exit 100, failing the build.
#
# apt-get update is required: the base layer wipes /var/lib/apt/lists.
# Pulls from Debian directly, not through the squid allowlist -- image builds
# don't go through the proxy.
ARG PI_APT_PACKAGES=""
RUN if [ -n "${PI_APT_PACKAGES}" ]; then \
        echo "installing apt packages: ${PI_APT_PACKAGES}"; \
        apt-get update && \
        apt-get install -y --no-install-recommends ${PI_APT_PACKAGES} && \
        rm -rf /var/lib/apt/lists/*; \
    fi

USER pi
ENV HOME=/home/pi
WORKDIR /work

# Extra Python packages, last layer so changing the list doesn't invalidate the
# npm/extension layers above it. Runs as `pi` (not root) so /opt/venv keeps its
# ownership and the agent can still `pip install` more at runtime.
#
# The guard matters: an empty PI_PIP_PACKAGES would expand to a bare
# `pip install` and fail the build.
#
# Unquoted expansion is intentional -- it word-splits the list into separate
# args. A `>` inside the *value* is not a shell redirection (operators are
# recognized before expansion), so `pandas>=2.0` survives intact. But spaces
# inside one spec do split: write `pandas>=2.0`, never `pandas >= 2.0`.
#
# Note this pulls from PyPI directly during the build, not through the squid
# allowlist -- image builds don't go through the proxy.
ARG PI_PIP_PACKAGES=""
RUN if [ -n "${PI_PIP_PACKAGES}" ]; then \
        echo "installing pip packages: ${PI_PIP_PACKAGES}"; \
        pip install --no-cache-dir ${PI_PIP_PACKAGES} || exit 1; \
        pip check || echo "warning: pip reports dependency conflicts (above)"; \
    fi

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
