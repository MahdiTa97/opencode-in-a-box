# OpenCode in Docker

Runs the OpenCode server in a hardened container, reachable only at
`http://opencode.localhost:8080` through nginx. The host install stays untouched
as a fallback.

Design: `docs/superpowers/specs/2026-11-14-opencode-docker-design.md`
Plan: `docs/superpowers/plans/2026-11-14-opencode-docker.md`

## Requirements

- Linux with Docker Engine and `docker compose` v2 (x86_64 or arm64).
- About 1.5 GB of disk for the image and the two volumes.
- Port 8080 free on loopback.
- `sudo` for Docker commands, unless your user is in the `docker` group
  (this host deliberately is not — see *Policy layer*).
- An OpenCode config at `~/.config/opencode/opencode.json(c)` is optional;
  without one the container starts with a minimal config.

## One-time setup

```bash
git clone <this-repo> ~/opencode-docker
cd ~/opencode-docker
./setup.sh
```

`setup.sh` creates `~/projects` and `~/.config/opencode` if missing, writes a
`.env` with a random password, your `HOST_UID`/`HOST_GID`, and `HOST_HOME=$HOME`,
then prints the next commands. It is safe to re-run: it only adds what is
missing and never overwrites an existing value.

`HOST_HOME` is required rather than defaulted, because `sudo docker` sets
`HOME=/root` and a wrong value makes Docker create empty directories over your
config files.

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
stored credential in the `oc-data` volume so it survives restarts.

Gateway key files are **not** mounted by default. The overlay drops any
provider whose `apiKey` is a `{file:…}` reference that does not exist inside the
container, and prints the dropped names to the container log. To use a gateway
again, add a single-file mount for its key under `volumes:` and recreate:

```yaml
      - ${HOST_HOME}/.secrets/gateway.key:/home/dev/.secrets/gateway.key:ro
```

## Accounts: login, switch, logout

Everything the container knows about accounts lives in the `oc-data` volume, not
on the host, so you manage it from inside the container. Use `-it`: the login
flow prints a URL and a code you open in your host browser.

```bash
# what is stored, and which account is active
sudo docker compose exec opencode opencode auth list

# add an account (a second login adds a second account, it does not replace)
sudo docker compose exec -it opencode opencode auth login opencode

# switch the active account (no name opens a picker)
sudo docker compose exec -it opencode opencode auth switch opencode "Personal"

# log out one account (no name opens a picker)
sudo docker compose exec -it opencode opencode auth logout opencode "Personal"
```

`auth login <target>` also takes `--method <id>` and repeated `--answer key=value`
for providers that use an API key instead of a browser flow, for example:

```bash
sudo docker compose exec -it opencode opencode auth login deepseek --answer apiKey=sk-...
```

Host accounts stay completely separate: logging out inside the container never
touches the desktop app's own credentials. To move the host's active Console
account in, use the export/import recipe above; to go the other way, run
`opencode auth export` inside the container and `opencode auth import` on the host.

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

`overlay.mjs` and `entrypoint.sh` are copied **into the image**, so editing them
requires `docker compose build` before `up -d`; `up -d` alone keeps running the
previous copy.

nginx resolves the `opencode` hostname once at startup, so it must be recreated
together with the server, or the UI returns 502 until it restarts.

## Password rotation

1. Edit `OPENCODE_PASSWORD` in `.env`.
2. `sudo docker compose up -d --force-recreate` — nginx caches the upstream
   address and the healthcheck reads the new password at start, so both
   containers must be recreated together.
3. Re-pair the desktop app: old links and session cookies stop working.

## IPv6

The compose file publishes nginx on `127.0.0.1:8080` **and** `[::1]:8080`
because `opencode.localhost` resolves to `::1` first on this host. On a machine
with IPv6 disabled, delete the `[::1]:8080` line or `docker compose up` fails
with an address-family error.

## Proxy

Egress from the container does not inherit the host's manual proxy. If model
calls fail, set `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` in `.env` (see
`.env.example`) and `sudo docker compose up -d`.

## Policy layer

The image bakes `policy/opencode.json` to `/etc/opencode/opencode.json`
(root-owned, read-only, 47 statements). **After changing the host's
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

## Context7 rate limits

The `context7` MCP server runs inside the container. With no key it is
anonymous, so Context7 answers "using Context7 anonymously" and throttles.
Inside the container there is no browser to sign in with, and `npx ctx7 setup`
would rewrite a config that is regenerated on every start, so the key goes in
`.env` instead:

```bash
printf 'CONTEXT7_API_KEY=%s\n' 'YOUR_KEY' >> .env
sudo docker compose build && sudo docker compose up -d --force-recreate
docker logs opencode-docker-opencode-1 2>&1 | grep 'context7 will use'
```

`overlay.mjs` copies the key into the generated config's
`mcp.servers.context7.environment`, which is written `0600` into the `oc-cache`
volume.
