# OpenCode in Docker

Runs the OpenCode server in a hardened container, reachable only at
`http://opencode.localhost:8080` through nginx. The host install stays untouched
as a fallback.

Design: `docs/superpowers/specs/2026-11-14-opencode-docker-design.md`
Plan: `docs/superpowers/plans/2026-11-14-opencode-docker.md`

## One-time setup

These host paths must already exist — Docker would otherwise create them
root-owned when it bind-mounts:

```bash
mkdir -p ~/projects ~/.config/opencode ~/.secrets
```

```bash
cd ~/opencode-docker
cp .env.example .env
chmod 600 .env
# set OPENCODE_PASSWORD in .env to something long:
#   openssl rand -base64 24
```

The Docker socket is root-only on this host, so every command is `sudo docker`.
Optional alias:

```bash
alias ocd='sudo docker compose -f ~/opencode-docker/docker-compose.yml'
```

## Start

```bash
sudo docker compose build
sudo docker compose up -d
sudo docker compose ps
```

## Connect

- Browser: <http://opencode.localhost:8080> (Basic auth, username `opencode`,
  password from `.env`).
- Desktop app: mint a one-time link and paste it into the app's server address
  field:

```bash
sudo docker compose exec opencode opencode pair --url http://opencode.localhost:8080
```

  The link is valid for 5 minutes; the session then lasts 30 days.
- TUI from the host: `opencode --server http://opencode.localhost:8080`.

## Verify

```bash
sudo bash tests/acceptance.sh
```

## Using OpenCode Go instead of a gateway key

The container starts with no stored account, so the OpenCode Console login from
the host has to be carried over once. Import through a file, not a pipe:
`auth import` reading stdin inside `docker compose exec` silently imports
nothing, while the same JSON as a file argument works.

```bash
CLI=~/.config/ai.opencode.desktop/cli/2.3.0-x64/opencode-cli
$CLI auth export > /tmp/oc-auth.json && chmod 600 /tmp/oc-auth.json
jq -c '[.[] | select(.integrationID=="opencode" and .active==true)]' /tmp/oc-auth.json > /tmp/oc-one.json
chmod 600 /tmp/oc-one.json

sudo docker compose exec -T opencode sh -c 'cat > /home/dev/oc-one.json' < /tmp/oc-one.json
sudo docker compose exec opencode opencode auth import /home/dev/oc-one.json
sudo docker compose exec opencode opencode auth list

rm -f /tmp/oc-auth.json /tmp/oc-one.json
sudo docker compose exec opencode rm -f /home/dev/oc-one.json
```

The last command should list `OpenCode Console  Personal  stored`. Keep the
stored credential in the `oc-data` volume so it survives restarts. With this in
place the two `~/.secrets/*.key` mounts can be removed from
`docker-compose.yml` if you do not use that gateway at all.

## Troubleshooting

**`403 Forbidden` from `registry-1.docker.io` while building.** Docker Hub
refuses metadata requests from some networks. Pull the two base images through
a mirror and retag them locally, once:

```bash
sudo docker pull docker.arvancloud.ir/library/node:24-bookworm-slim
sudo docker tag docker.arvancloud.ir/library/node:24-bookworm-slim node:24-bookworm-slim
sudo docker pull docker.arvancloud.ir/library/nginx:1.27-alpine
sudo docker tag docker.arvancloud.ir/library/nginx:1.27-alpine nginx:1.27-alpine
```

Then build without `--pull`, which is what asks Docker Hub for metadata.

## Logs, stop, destroy, upgrade

```bash
sudo docker compose logs -f opencode     # the server log, tailed by the entrypoint
sudo docker compose down                 # stop, keep sessions
sudo docker compose down -v              # destroy sessions, snapshots and cache
```

Upgrade: edit the pinned `@opencode/cli@2.3.0` in the `Dockerfile`, then

```bash
sudo docker compose build --pull && sudo docker compose up -d --force-recreate
```

nginx resolves the `opencode` hostname once at startup, so it must be recreated
together with the server, or the UI returns 502 until it restarts.

## Password rotation

1. Edit `OPENCODE_PASSWORD` in `.env`.
2. `sudo docker compose up -d` (recreates the service container).
3. Re-pair the desktop app: old links and session cookies stop working.

## Proxy

Egress from the container does not inherit the host's manual proxy. If model
calls fail, set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in `.env` (see
`.env.example`) and `sudo docker compose up -d`.

## Policy layer

The image bakes `policy/opencode.json` to `/etc/opencode/opencode.json`
(root-owned, read-only, 31 statements). **After changing the host's
`/etc/opencode/opencode.json`, re-copy it into `policy/` and rebuild**, or the
container keeps enforcing the old rules:

```bash
cp /etc/opencode/opencode.json policy/opencode.json
sudo docker compose build && sudo docker compose up -d
```

The user config is mounted read-only over the writable config directory, so
rules cannot be rewritten from inside even by an interpreter.

## Known costs

- `browse` and the Chrome extension do not work inside the container.
- `context7` works only because the package is baked into the image.
- No SSH agent, git token, or `gh` inside: clone/fetch/push happen on the host.
  Projects are mounted read-write, so `.venv`, installs, builds and tests work.
- The agent can read the provider key files: it needs them to call the model.
- Docker is not a VM; the project mount is fully writable, so a hostile
  `package.json` still runs.
- Outbound internet is unrestricted; a leaked key is possible in principle.
