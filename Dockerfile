FROM node:24-bookworm-slim

ARG UID=1000
ARG GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep curl ca-certificates jq python3 openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Pinned: upgrading OpenCode is an explicit edit of this line.
RUN npm install -g @opencode/cli@2.3.0 @upstash/context7-mcp@4.7.0 \
 && npm cache clean --force

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
COPY policy/opencode.json /etc/opencode/opencode.json
RUN chown root:root /etc/opencode/opencode.json && chmod 644 /etc/opencode/opencode.json

COPY overlay.mjs /usr/local/lib/opencode-docker/overlay.mjs
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
