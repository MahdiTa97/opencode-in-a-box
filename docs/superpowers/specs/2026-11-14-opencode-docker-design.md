# OpenCode in Docker — design

Date: 2026-11-14
Status: awaiting approval

## Intent and why

The user runs OpenCode on their own Linux laptop. The agent's shell tool has the
host user's full authority; permission rules block the obvious paths but cannot
contain an agent that reads a secret through an interpreter (`python3 -c`) or
that rewrites its own rules through a tool we did not anticipate. The remaining
risk is not "the agent is malicious", it is "the agent's mistakes are unbounded".

Goal: move the agent, its shell, and its file access into a container so the
blast radius becomes "this container and the project directory mounted into it".
Access is for the owner only, from this laptop.

## Goals

- The agent's shell runs inside a container, as a non-root user, with no access
  to `~/.ssh`, `~/.aws`, `~/.gnupg`, the OpenCode auth store, the host package
  manager, systemd, or the Docker socket.
- The desktop app and the web UI both keep working, against the containerized
  server.
- A human-readable local address: `http://opencode.localhost:8080`.
- Reversible and disposable: one command to destroy and recreate.
- The existing host install stays untouched as a fallback.

## Non-goals

- Reaching the server from other devices or the internet.
- Public DNS, certificates, or TLS. (`*.localhost` is a secure context; the
  traffic never leaves the loopback interface.)
- Running Chrome, `browse`, or any GUI automation inside the container.
- Isolating the model provider: prompts and code still leave the machine.
- A general-purpose dev container for every language.

## Anti-goals (would mean this design failed)

- A container that mounts the Docker socket, `$HOME`, or an X11/Wayland socket.
- A second server exposed on `0.0.0.0`.
- A setup where the user cannot tell which environment a session is running in.

## Constraints discovered

- The runtime is `@opencode/cli` 2.3.0 (npm, platform binaries under
  `@opencode/cli-linux-x64`). V1's install script redirects to the `v1` branch
  and must not be used.
- `opencode serve --hostname 0.0.0.0 --port 4097` is the documented way to run
  the server in Docker. `OPENCODE_PASSWORD` sets a fixed password; HTTP clients
  use Basic auth with username `opencode`.
- The web UI is served by the same server and is password protected. `opencode
  pair` prints a one-time link (valid 5 minutes) that the desktop app accepts in
  its server address field; sessions last 30 days.
- **Verified on this machine, 2026-11-14:** `pair` talks to the *managed
  background service*, not to a standalone `serve` process — it accepts no
  `--server` flag. In an isolated `HOME` with `opencode service start` on port
  4099 and `OPENCODE_PASSWORD` set, `opencode pair --url
  http://opencode.localhost:8080` printed
  `http://opencode.localhost:8080/auth/connect/<token>`. Against a bare `serve`
  process there is no way to mint a link. The container therefore runs the
  managed service, not `serve` in the foreground.
- Basic auth verified the same way: no credentials → 401, `-u
  opencode:<password>` → 200 on `/api/info`, a wrong password → 401.
- OpenCode has no TLS of its own.
- Config lives in `~/.config/opencode`, and plugins install `node_modules` there,
  so that directory must be writable inside the container.
- Sessions, snapshots, and the database live in `~/.local/share/opencode`.
- The user's provider config reads keys from `{file:~/.secrets/*.key}`.

## Approaches considered

1. **Container as the only environment** (chosen). Server in Docker, desktop app
   connects to it, web UI through nginx. Full isolation, but `browse` and other
   host-attached tools are gone, and every toolchain must exist in the image.
2. **Container only for risky repositories.** Host install stays the default;
   a wrapper raises the container for unfamiliar code. Keeps everything, but two
   environments and the safe path is not the default path.
3. **bwrap instead of Docker.** Lighter, no image maintenance, but no network
   boundary and more fragile across tools.

The user chose 1: they want the isolated path to be the only path.

## Design

### Compose topology

Two services, no published ports except one loopback binding.

- `opencode` — the server. Internal network `edge` plus an `egress` network for
  provider calls. No ports published.
- `nginx` — reverse proxy. Publishes `127.0.0.1:8080`, only on `edge`.
- nginx is the only thing a browser or the app talks to; the server is not
  reachable from the host directly.

### Image

Base `node:24-bookworm-slim`. Installed: `git`, `ripgrep`, `curl`,
`ca-certificates`, `jq`, `python3`, `openssh-client`, plus
`npm i -g @opencode/cli@2.3.0` (version pinned; upgrade is an explicit edit).

A non-root user `dev` is created with UID/GID passed as build args from the host
(`id -u` / `id -g`) so files written into the project stay owned by the host
user and git sees no spurious changes.

The image also bakes in the host's hardened policy layer at
`/etc/opencode/opencode.json`, so the container inherits today's 31 hard denies
and the user's config cannot loosen them from inside.

### Mounts

| Host | Container | Mode |
| --- | --- | --- |
| `~/.config/opencode` | `/home/dev/host-config` | **ro** (read at start, never written) |
| `~/.secrets/<provider>.key` | `/home/dev/.secrets/<provider>.key` | not mounted by default; single-file ro mount if used |
| project directories | `/work/<name>` | rw |
| named volume `oc-data` | `/home/dev/.local/share/opencode` | rw |
| named volume `oc-cache` | `/home/dev/.cache/opencode` | rw |

Never mounted: the Docker socket, `$HOME`, `~/.ssh`, `~/.aws`, `~/.gnupg`,
`/run/user/1000`, X11 or Wayland sockets, `/etc` beyond the baked policy file.

Mounting the two key files individually (not the directory) means the container
cannot list `~/.secrets`.

The two config files are mounted read-only **on top of** the writable config
directory. The directory has to be writable because plugins install
`node_modules` into it, but rules alone cannot stop a write through an
interpreter; a read-only bind stops it at the kernel, which is the only place
that argument actually holds. Consequence: the agent can add files next to the
config but cannot change the rules, the MCP list, or the plugin pins.

Plugin and skill *content* under that directory is still writable by design. The
`/etc` policy layer remains the authority for anything that matters.

Project directories are mounted read-write: inside the container the agent can
create `.venv`, install packages, run builds and tests, and write code exactly as
it can on the host. The only host capability deliberately withheld is *git
credentials* (no `~/.ssh`, no token, no `gh`), so clone/fetch/push stay on the
host. If that ever blocks real work, the narrow fix is one deploy key for one
repository, mounted read-only — a separate decision, not part of this design.

### Runtime hardening

`cap_drop: ALL`, `security_opt: no-new-privileges:true`, `init: true`,
`tmpfs: /tmp`, `pids_limit`, a memory limit, and no `user: root`. nginx runs
read-only with its own tmpfs. Restart policy `unless-stopped`.

### Volumes and ownership

The server runs as `dev` (UID/GID from the host), so the two named volumes must
be owned by that UID. A one-shot `init` service, running as root with only
`CAP_CHOWN`, fixes ownership and exits; `opencode` starts with
`depends_on: { init: { condition: service_completed_successfully } }`. This keeps
`cap_drop: ALL` on the long-lived container.

### Egress and proxy

The `opencode` service reaches the internet through the default bridge (NAT), so
model calls, `npm install`, `pip`, and `git fetch` from public remotes work. This
host uses a manual proxy (`proxy.example:8080`) and the MCP wrapper resolves it
from GNOME settings; the container does not inherit that, so `HTTP_PROXY`,
`HTTPS_PROXY`, and `NO_PROXY` are passed through from an optional `.env` and
validated with one `curl` before trusting it.

Egress is deliberately unrestricted. Narrowing it to provider endpoints would
need a forward proxy or firewall sidecar and would break `npm install`; the
compensating controls are the scoped, rotatable key and the fact that the
container holds nothing else worth exfiltrating.

### MCP servers

`browse` is host-attached and cannot run in the container. `context7` runs as a
node MCP server and needs the package on `PATH` inside the image, not the host
nvm wrapper.

Because the config files are read-only in the container, the container's MCP
list cannot be edited in place. The entrypoint generates a container-only
`opencode.jsonc` into the writable cache volume and points
`OPENCODE_CONFIG` at it: the host file is read, `browse` is dropped, and
`context7` is rewritten to the in-image command. Regeneration happens on every
start, so host changes are picked up. The host's own files are never modified.

### nginx

Reverse proxy to `http://opencode:4097` with HTTP/1.1, Upgrade/Connection
headers, `proxy_buffering off`, and long read timeout (the UI streams).

Headers: `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
`X-Frame-Options: DENY`, `Permissions-Policy` minimal, and a CSP started in
`Content-Security-Policy-Report-Only` mode. CSP is tightened only after the UI
has been exercised; a strict policy on someone else's SPA breaks it.

Rate limiting on `/auth/connect/` and on failed basic-auth attempts.
`client_max_body_size` set high enough for attachments.

### Access

- Browser: `http://opencode.localhost:8080`.
- nginx publishes both `127.0.0.1:8080` and `[::1]:8080`: on this host
  `opencode.localhost` resolves to `::1` first, so an IPv4-only binding would
  break the human-readable URL for IPv6-first clients.
- Desktop app: inside the container,
  `opencode pair --url http://opencode.localhost:8080`, then paste the printed
  link into the app's server address field. The link is one-time and expires in
  5 minutes. This only works because the container runs the managed service (see
  Constraints and Lifecycle).
- TUI from the host: `opencode --server http://opencode.localhost:8080`.
- Fallback if a client refuses the name: `http://127.0.0.1:8080`.

### Docker invocation

The socket is root-only on this host (`srw------- root docker`) and the user was
removed from the `docker` group deliberately, so every command runs as
`sudo docker compose …`. A shell alias (`ocd`) keeps that short. Rootless Docker
or Podman would remove the `sudo`, but change volume ownership and UID mapping,
so they are a later step, not part of this design.

### Password and auth

`OPENCODE_PASSWORD` comes from a `.env` file next to the compose file (mode
600, git-ignored). Basic auth is OpenCode's; nginx adds no second credential
because that would break the app's pairing.

### Lifecycle

- The container's entrypoint (PID 1 is `tini` via `init: true`):
  1. `opencode service set hostname 0.0.0.0`
  2. `opencode service set port 4097`
  3. `opencode service set password "$OPENCODE_PASSWORD"` (and
     `opencode service set env OPENCODE_PASSWORD ...` so restarts keep it)
  4. generate the container-only config, `export OPENCODE_CONFIG=...`
  5. `opencode service start`
  6. `exec tail -F ~/.local/share/opencode/log/opencode.log` so the container
     stays in the foreground and `docker logs` shows the server.
  Steps 1–3 are idempotent and stored in the `oc-data` volume, so a restart keeps
  the same password and port. The service is a child process of this container;
  stopping the container stops it, so no host pid can leak out.
- Healthcheck: `curl -fsS -u "opencode:$OPENCODE_PASSWORD"
  http://127.0.0.1:4097/api/info`, interval 30s, start period 40s.
- Start: `sudo docker compose up -d`.
- Destroy: `sudo docker compose down -v` (sessions, snapshots, and cache go with it).
- Upgrade: edit the pinned version, then
  `sudo docker compose build --pull && sudo docker compose up -d`.
- Authenticate providers once inside the container; the token lives in the
  `oc-data` volume, not in the host's auth store.

### Known costs, stated up front

- `browse` and the Chrome extension do not work inside the container.
- `context7` runs only because the package is installed in the image.
- `node_modules` of a project built on the host may need reinstalling inside.
- The agent can read the provider key files: it needs them to call the model.
- No SSH agent or git credentials inside: private remotes are fetched and
  pushed from the host; the container works on local history. `gh` is not
  installed. Code, builds, and `.venv` all work normally inside.
- Pairing links are minted by the managed service only, so the container runs
  `opencode service start` and keeps a `tail -F` in the foreground instead of a
  plain `serve`; `docker logs` shows the server log rather than the server's own
  stdout.
- Docker is not a VM; kernel escapes are rare, not impossible.
- The project mount is fully writable: a hostile `package.json` still runs.
- The agent has unrestricted outbound internet, so a leaked key is possible in
  principle; key scoping and rotation are the controls.

### Acceptance tests

1. `sudo docker compose exec opencode id` shows a non-root UID matching the host.
2. `ls ~/.ssh` inside the container fails (not mounted); `/home/dev/.secrets`
   is empty unless a key file was deliberately mounted.
3. The same interpreter writing `/home/dev/host-config/opencode.jsonc` fails with
   a read-only filesystem error.
4. `/home/dev/.config/opencode` contains no `opencode.json(c)`, so the overlay and
   `/etc/opencode` are the only configuration layers.
5. `sudo` is absent inside the container.
6. `docker` is absent inside the container.
7. From the host, `curl http://127.0.0.1:8080/api/info` without credentials
   returns 401; `curl -g http://[::1]:8080/api/info` behaves the same.
8. The desktop app connects through the pairing link and lists sessions.
9. The web UI loads at `http://opencode.localhost:8080`, and the CSP report-only
   console shows no violations on a normal session.
10. Editing `~/.config/opencode/opencode.jsonc` from the agent inside the
    container is denied by the baked `/etc` policy.
11. A file created in `/work/<name>` has the host user's UID and GID.
12. A model call succeeds from inside the container, with the proxy either
    unset or set as documented.

## What the user decided

- Container is the primary environment, not an occasional one.
- Loopback only; no remote access, no public DNS, no TLS.
- Local name `opencode.localhost`.
- Keep the host install as a fallback.

## Left to the builder

- Exact CSP directive list, tuned against the real UI.
- Whether to mount one project root or an explicit list of projects.
- Whether to add language toolchains to the base image or provide a per-project
  image pattern.
- Whether the `.env` password is generated once or rotated on a schedule.
