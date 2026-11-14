# OpenCode in Docker

Runs the OpenCode server in a hardened container, reachable only at
`http://opencode.localhost:8080` through nginx. The host install stays untouched
as a fallback.

Design: `docs/superpowers/specs/2026-11-14-opencode-docker-design.md`
Plan: `docs/superpowers/plans/2026-11-14-opencode-docker.md`

## One-time setup

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

## Logs, stop, destroy, upgrade

```bash
sudo docker compose logs -f opencode     # the server log, tailed by the entrypoint
sudo docker compose down                 # stop, keep sessions
sudo docker compose down -v              # destroy sessions, snapshots and cache
```

Upgrade: edit the pinned `@opencode/cli@2.3.0` in the `Dockerfile`, then

```bash
sudo docker compose build --pull && sudo docker compose up -d
```

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
