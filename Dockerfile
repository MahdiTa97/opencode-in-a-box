FROM node:24-bookworm-slim

ARG UID=1000
ARG GID=1000

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ripgrep curl ca-certificates jq python3 openssh-client \
 && rm -rf /var/lib/apt/lists/*

# Pinned: upgrading OpenCode is an explicit edit of this line.
RUN npm install -g @opencode/cli@2.3.0 @upstash/context7-mcp \
 && npm cache clean --force

RUN groupadd -g "${GID}" dev \
 && useradd --create-home --uid "${UID}" --gid "${GID}" --shell /bin/bash dev \
 && mkdir -p /work /home/dev/.secrets \
 && chown dev:dev /work

# The host's hardened policy layer, baked in. The user config cannot loosen it.
COPY policy/opencode.json /etc/opencode/opencode.json
RUN chown root:root /etc/opencode/opencode.json && chmod 644 /etc/opencode/opencode.json

COPY overlay.mjs /usr/local/lib/opencode-docker/overlay.mjs
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER dev
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
