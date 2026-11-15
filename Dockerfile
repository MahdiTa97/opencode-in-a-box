# Base image pinned by digest: a tag can be re-pointed at different content,
# a digest cannot. Override when building from a registry mirror:
#   --build-arg NODE_IMAGE=docker.arvancloud.ir/library/node:24-bookworm-slim
ARG NODE_IMAGE=node:24-bookworm-slim@sha256:dc26ae92c9fb15cf6b1d63e20f0944b2efe0f115b20e00be48fb23fceb061c54
FROM ${NODE_IMAGE}

ARG UID=1000
ARG GID=1000

# JS/TS/frontend toolchain. The base image already brings node and npm; the
# package managers below are pinned so a project's lockfile behaves the same
# inside the container as on the host.
#   INSTALL_PLAYWRIGHT=1 adds Chromium for e2e tests (~1.2 GB); off by default.
ARG INSTALL_PLAYWRIGHT=0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep curl ca-certificates jq python3 openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Pinning policy (see README, Toolchain):
#   - @opencode/cli and @upstash/context7-mcp: exact. A major bump can change the
#     config schema or the plugin API, which would silently weaken the policy floor.
#   - pnpm: caret. Minor and patch releases are safe for lockfiles, majors are not.
#   - yarn: 1.22.22 is the final classic release; nothing will be published after it.
# The base image ships corepack shims at /usr/local/bin/{yarn,yarnpkg,pnpm,pnpx};
# npm refuses to overwrite them, so drop them first and install real versions.
RUN rm -f /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/pnpm /usr/local/bin/pnpx \
 && npm install -g @opencode/cli@2.3.0 @upstash/context7-mcp@4.7.0 "pnpm@^12.18.0" yarn@1.22.22 \
 && npm cache clean --force

# Optional browser for e2e tests. Browsers live outside $HOME so a volume mount
# can never hide them, and outside /tmp so the noexec tmpfs does not break them.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN if [ "${INSTALL_PLAYWRIGHT}" = "1" ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 \
        libcups2 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0 libgtk-3-0 \
        libnspr4 libnss3 libx11-6 libxcomposite1 libxdamage1 libxext6 \
        libxfixes3 libxkbcommon0 libxrandr2 xdg-utils \
      && rm -rf /var/lib/apt/lists/* \
      && npm install -g playwright@1.65.1 \
      && playwright install --with-deps chromium \
      && chmod -R a+rX /opt/ms-playwright \
      && npm cache clean --force; \
    fi

# The base image already ships a user and group at 1000 (the `node` account),
# so rename whatever occupies the host UID/GID instead of failing to create it.
RUN set -eu; \
    if getent group "${GID}" >/dev/null; then \
      [ "$(getent group "${GID}" | cut -d: -f1)" = "dev" ] || \
        groupmod -n dev "$(getent group "${GID}" | cut -d: -f1)"; \
    else \
      groupadd -g "${GID}" dev; \
    fi; \
    if getent passwd "${UID}" >/dev/null; then \
      [ "$(id -un "${UID}")" = "dev" ] || \
        usermod -l dev --move-home -d /home/dev -g "${GID}" "$(id -un "${UID}")"; \
    else \
      useradd --create-home --uid "${UID}" --gid "${GID}" --shell /bin/bash dev; \
    fi; \
    mkdir -p /work /home/dev/.secrets /home/dev/.local/share/opencode /home/dev/.local/state /home/dev/.cache/opencode; \
    chown -R dev:dev /home/dev /work

# The host's hardened policy layer, baked in. The user config cannot loosen it.
# POLICY_SHA is stamped in by `oc up --build`, so `oc doctor` can tell whether
# the running image carries the policy this tree defines.
ARG POLICY_SHA=unknown
COPY policy/opencode.json /etc/opencode/opencode.json
RUN chown root:root /etc/opencode/opencode.json && chmod 644 /etc/opencode/opencode.json
LABEL org.opencode-docker.policy-sha="${POLICY_SHA}"

COPY overlay.mjs /usr/local/lib/opencode-docker/overlay.mjs
COPY commands/ /usr/local/lib/opencode-docker/commands/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /work

# The root filesystem is read-only at runtime, so every cache must live in a
# writable mount: oc-cache is mounted at ~/.cache/opencode.
ENV npm_config_cache=/home/dev/.cache/opencode/npm \
    COREPACK_HOME=/home/dev/.cache/opencode/corepack \
    NPM_CONFIG_UPDATE_NOTIFIER=false

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
