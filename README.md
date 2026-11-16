# OpenCode in Docker

Runs the OpenCode server in a hardened container, reachable only at
`http://opencode.localhost:8080` through nginx. The host install stays untouched
as a fallback.

Design: `docs/superpowers/specs/2026-11-14-opencode-docker-design.md`
Plan: `docs/superpowers/plans/2026-11-14-opencode-docker.md`

Working in this repository with an agent? `AGENTS.md` is loaded automatically
and lists the rules that are easy to break (what needs a rebuild, what is
human-only, what must never be edited by hand).

## Requirements

- Linux with Docker Engine and `docker compose` v2 (x86_64 or arm64).
- About 1.5 GB of disk for the image and the two volumes (plus ~1.2 GB if you
  build with `INSTALL_PLAYWRIGHT=1`).
- Port 8080 free on loopback.
- `sudo` for Docker commands, unless your user is in the `docker` group
  (this host deliberately is not — see *Policy layer*).
- An OpenCode config at `~/.config/opencode/opencode.json(c)` is optional;
  without one the container starts with a minimal config.

`./setup.sh` prints a preflight block before it writes anything — compose
version, kernel seccomp support, how Docker is reachable, IPv6, port 8080, and
the cgroup generation. It stops early on a kernel without seccomp instead of
failing ten minutes into a build.

### Platform compatibility

| Host | Status | What to know |
|---|---|---|
| Linux x86_64 / arm64, cgroup v2 | Supported, tested | The intended target. |
| Linux with cgroup v1 | Works | Memory and pids limits still apply; snapshots and OOM behaviour may differ. |
| Linux without IPv6 | Works after one edit | Drop the `[::1]:8080` publish; `opencode.localhost` resolves to `127.0.0.1`. |
| SELinux enforcing (Fedora, RHEL) | Untested | Bind mounts need the `:z` suffix, and `no-new-privileges` labels may need adjusting. |
| No AppArmor (Fedora, Arch, Alpine) | Works | Nothing here depends on AppArmor; the seccomp profile is what confines syscalls. |
| Kernel without seccomp | Not supported | `setup.sh` refuses to continue; the container profile cannot be applied. |
| Docker Desktop (macOS, Windows) | Untested | Loopback publishing and UID mapping behave differently; `opencode.localhost` is not special there. |
| Rootless Docker / Podman | Untested | Volume ownership and port 8080 (<1024 is fine, but subuid mapping is not) need checking. |

Networks that block Docker Hub: the build fails with `403` on `--pull`; see
*Troubleshooting* for the mirror workaround. Never build with `--pull`.

## One-time setup

```bash
git clone <this-repo> ~/opencode-docker
cd ~/opencode-docker
./setup.sh
```

`setup.sh` creates `$HOME/projects` and `~/.config/opencode` if missing, writes a
`.env` with a random password, your `HOST_UID`/`HOST_GID`, `HOST_HOME=$HOME` and
`PROJECTS_DIR=$HOME/projects`, then prints the next commands. It is safe to
re-run: it only adds what is missing and never overwrites an existing value.

`HOST_HOME` is required rather than defaulted, because `sudo docker` sets
`HOME=/root` and a wrong value makes Docker create empty directories over your
config files.

### Where your code lives

`PROJECTS_DIR` is the one host tree mounted read-write into the container, at
`/work`. It must be an **absolute** path; `setup.sh` refuses `/` and `$HOME`
itself and creates the directory if it is missing.

```bash
# .env
PROJECTS_DIR=/home/you/code
```

Everything under it is readable and writable by the agent, so point it at a
parent directory of your projects, not at anything wider. Projects living
outside it are simply not visible inside the container.

The Docker socket is root-only on this host, so every command is `sudo docker`.
Optional alias:

```bash
alias ocd='sudo docker compose -f ~/opencode-docker/docker-compose.yml'
```

## Start

```bash
./bin/oc up --build    # builds with the policy digest label, waits for health
./bin/oc status
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

## Toolchain

The image is built for JS/TS/frontend work and stays small:

| tool | version | notes |
|------|---------|-------|
| `node` | the base image's (`v24.x`) | includes `npm` |
| `pnpm` | 12.18.0 | pinned, so a `pnpm-lock.yaml` behaves as on the host |
| `yarn` | 1.22.22 | classic |
| `git`, `rg`, `jq`, `curl`, `python3` | distro | `python3` also serves `node-gyp` |

The base image ships corepack shims at `/usr/local/bin/{yarn,yarnpkg,pnpm,pnpx}`.
The Dockerfile removes them before installing the pinned versions; without that,
`npm install -g yarn` fails with `EEXIST: file already exists`.

`node_modules` built on the host inside `PROJECTS_DIR` are visible in the
container, but native addons are **not** interchangeable if the host runs a
different Node major. If something fails with `NODE_MODULE_VERSION`, run
`pnpm rebuild` (or delete `node_modules`) inside the container.

### Version policy

Nothing is on `latest`. A `latest` build takes whatever exists that day, so the
image stops being reproducible and a silent upstream change can weaken what the
acceptance tests check. Strictness is split by blast radius:

| package | pin | why |
|---------|-----|-----|
| `@opencode/cli` | exact (`2.3.0`) | a major bump has changed the config schema and the plugin API before; that is the policy floor |
| `@upstash/context7-mcp` | exact (`4.7.0`) | a protocol change kills MCP silently |
| `pnpm` | caret (`^12.18.0`) | minor/patch releases stay lockfile-compatible |
| `yarn` | exact (`1.22.22`) | final classic release; nothing newer will ship |
| base image | tag (`node:24-bookworm-slim`) | floats within 24.x; pin a digest if you want it frozen |

Check where you stand before deciding anything:

```bash
./scripts/check-updates.sh
```

It prints pinned vs latest for every tool and flags a major jump. To upgrade,
edit the one line in the `Dockerfile`, rebuild, then re-run
`sudo bash tests/acceptance.sh`: the tests are what tell you the bump was safe.

### Browser for e2e tests

Chromium is **off by default** because it adds ~1.2 GB. When you need
Playwright:

```bash
sudo docker compose build --build-arg INSTALL_PLAYWRIGHT=1
sudo docker compose up -d --force-recreate
```

Browsers are installed at `/opt/ms-playwright` (set via
`PLAYWRIGHT_BROWSERS_PATH`), so a `$HOME` volume can never hide them. Projects
should install `playwright` in their own `devDependencies`; the global install
only provides the browser binaries.

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
      - ${HOST_HOME}/.secrets/<provider>.key:/home/dev/.secrets/<provider>.key:ro
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
refuses metadata requests from some networks. Both base images are pinned by
digest, so retagging a mirrored image under its old tag no longer satisfies the
build — pull through the mirror and point the build at it instead:

```bash
sudo docker pull docker-mirror.example/library/node:24-bookworm-slim
sudo docker pull docker-mirror.example/library/nginx:1.27-alpine
sudo docker compose build --build-arg NODE_IMAGE=docker-mirror.example/library/node:24-bookworm-slim
echo 'NGINX_IMAGE=docker-mirror.example/library/nginx:1.27-alpine' >> .env
```

`docker-mirror.example` stands for any registry mirror your network can reach;
substitute its host. Do not pass `--pull`: that is the request Docker Hub
refuses. The trade-off is explicit — a mirror tag is not content-addressed, so
the build is pinned only on machines that can reach Docker Hub.

**The desktop app says `Failed to send prompt — Authentication required`.** The
app has fallen back to a local service of its own instead of the container.
Two things make it worse than it looks:

```bash
# what the app is actually talking to
ss -ltnp | grep -E ':4097|:8080'
```

If `:4097` is listening on `0.0.0.0`, a host-side agent service is reachable
from the network. Stop it and re-point the app at the container:

```bash
CLI=~/.config/ai.opencode.desktop/cli/2.3.0-x64/opencode-cli
$CLI service stop
rm -f ~/.config/opencode/service.json ~/.local/state/opencode/service.json
cd ~/opencode-docker
sudo docker compose exec opencode opencode pair --url http://opencode.localhost:8080
```

Paste the printed link into the app's server address field. With the stale
`service.json` gone, any future fallback binds loopback only. If `:49374` comes
back anyway, the app is restarting it — see the next entry.

Why it happened: the server signs sessions with a secret it keeps in
`~/.local/state`. That path used to be a tmpfs, so every `--force-recreate`
wiped the secret and the app's stored pairing became invalid. It is now the
named volume `oc-state`, so a restart or upgrade keeps the pairing. Deleting
that volume (`docker compose down -v`) signs the app out; pair once more.

A pairing link is single use and expires after five minutes. Opening a used
one in a browser returns `Authentication required`, which is not an error in
the app. Mint a fresh one:

```bash
cd ~/opencode-docker
curl -s -X POST -u "opencode:$(grep '^OPENCODE_PASSWORD=' .env | cut -d= -f2-)" \
  http://opencode.localhost:8080/api/pair | jq -r '.code'
```

**The desktop app keeps starting its own local service.** The app bundles its
own `opencode-cli` and runs `opencode-cli serve --service` on
`127.0.0.1:49374` at every start. The app supervises that process and respawns
it within a second, so `service stop`, deleting `service.json`, and clearing
the app's `Local Storage` all leave it running: the server row reappears, and a
new session is created there instead of in the container.

Shadow the bundled binary so it refuses that one flag and passes everything
else through:

```bash
cd ~/.config/ai.opencode.desktop/cli/*-x64    # the app's bundled CLI
[ -s opencode-cli.real ] || cp opencode-cli opencode-cli.real
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--service" ] && exit 0; done\nexec "$(dirname "$0")/opencode-cli.real" "$@"\n' > opencode-cli.shim
chmod +x opencode-cli.shim && mv -f opencode-cli.shim opencode-cli
pkill -f 'opencode-cli serve --service'
```

`mv` is required: writing over a running executable fails with `text file
busy`. Renaming swaps the directory entry, so the running process keeps the old
inode and the next start picks up the shim. `--version`, `api` and `service`
still work because the shim forwards every other argument.

The path is version-scoped. A desktop-app update installs a fresh
`cli/<version>-x64` directory, the shim is gone with the old one, and the local
service returns — re-run the block in the new directory. To undo it,
`mv -f opencode-cli.real opencode-cli`.

## `oc` — one command instead of seven

`bin/oc` is a POSIX-sh shortcut for every routine job here. It writes nothing,
owns no state, and is safe to run from two terminals at once.

```bash
export PATH="$PWD/bin:$PATH"     # or symlink it into ~/.local/bin
oc help
```

| command | runs |
|---|---|
| `oc up [--build]` | `compose up -d --wait --wait-timeout 90`; `--build` rebuilds and stamps the policy digest |
| `oc down [--volumes --yes]` | `compose down`; `--volumes` needs `--yes` because it destroys sessions |
| `oc restart` | `compose up -d --force-recreate --wait` (recreate, not restart: nginx caches the upstream) |
| `oc status [--json]` | `compose ps`, one JSON object per service with `--json` |
| `oc pair` | mints a one-time pairing link for the desktop app |
| `oc shell [cmd…]` | a shell inside the container, or one command |
| `oc logs [-f] [--since W]` | the server log |
| `oc backup [dir]` | `scripts/backup.sh` |
| `oc restore --check FILE` / `oc restore FILE --yes` | `scripts/restore.sh` |
| `oc audit [window]` | `scripts/audit.sh` |
| `oc config` | validates `.env` and the compose file |
| `oc doctor [--json]` | the eight checks below |

Docker normally needs elevated rights here; any command that needs the daemon
re-runs itself through `sudo`. Set `OC_NO_SUDO=1` to disable that and fail with
the reason instead. `OC_VERBOSE=1` prints every command first.

### `oc doctor`

| # | check |
|---|---|
| 1 | `.env` exists, is mode 600, and has a real password |
| 2 | `HOST_HOME`/`PROJECTS_DIR` are set, and the latter is not `/` or `$HOME` |
| 3 | `docker compose config -q` accepts this environment |
| 4 | the image is newer than the last change to `Dockerfile`, `overlay.mjs`, `entrypoint.sh`, `commands/`, `policy/`, `seccomp/` |
| 5 | `seccomp/opencode.json` matches `scripts/gen-seccomp.mjs` |
| 6 | the image's `org.opencode-docker.policy-sha` label matches `policy/opencode.json` |
| 7 | `opencode` is healthy and both loopback addresses answer `401` |
| 8 | `/etc/opencode/opencode.json` has the same policy count as this tree |

`PASS` is good, `WARN` is survivable, `FAIL` exits 1. A `WARN` or `FAIL`
carries a `fix:` line with the command that resolves it.

### Help, colour, and machine-readable output

```
oc help              # the table above
oc help up           # usage, flags, two examples, and what it touches
oc up --help         # the same page
oc doctor --json | jq .
```

Every command has its own page, and `oc <cmd> --help` is the same text, so
there is exactly one place where help lives. A misspelled command gets a
suggestion (`oc stauts` → `did you mean: status?`) instead of a wall of output.

Colour is used only when the stream it is written to is a terminal (`stdout`
for results, `stderr` for errors), `TERM` is not `dumb`, and `NO_COLOR` is
unset or empty — the convention from [no-color.org](https://no-color.org), so
piping or redirecting already gives plain text. Icons follow the same rule:
`✓ ! ✗` appear only on a terminal, so a pipe or a log file contains nothing but
ASCII. `OC_ASCII=1` also drops them on a terminal, for fonts that render them
badly. The words `PASS`/`WARN`/`FAIL` are present in every mode, so
`oc doctor | grep FAIL` always works, and `--json` output is plain on both
streams.

Exit codes: `0` success, `1` the environment or a check is wrong, `2` usage
error (unknown command, unknown flag, a flag missing its value). Usage errors
are detected *before* anything runs as root, so a typo never asks for a
password.

Checks 4 and 6 are the two
that caught real problems here: a stale image ran for an hour while every test
passed, because the tests read the tree and the container ran the old copy.

Never build with `sudo docker compose build` directly — that leaves the policy
label at `unknown` and `oc doctor` will (correctly) complain. Use
`oc up --build`.

## Logs, stop, destroy, upgrade

```bash
sudo docker compose logs -f opencode     # the server log, tailed by the entrypoint
sudo docker compose down                 # stop, keep sessions
sudo docker compose down -v              # destroy sessions, snapshots and cache
```

Upgrade: edit the pinned `@opencode/cli@2.3.0` in the `Dockerfile`, then

```bash
./bin/oc up --build
./bin/oc doctor
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
(root-owned, read-only, 53 statements). **After changing the host's
`/etc/opencode/opencode.json`, re-copy it into `policy/` and rebuild**, or the
container keeps enforcing the old rules:

```bash
cp /etc/opencode/opencode.json policy/opencode.json
./bin/oc up --build
```

The host config directory is mounted read-only at `/home/dev/host-config`, never
as the container's global config directory: `OPENCODE_CONFIG` only overrides the
keys it defines, so a global config placed there would leak `browse` and
credential-less providers into the running server. The overlay is regenerated
from the host files at every start and served to the server as an extra layer.

### Only you can change the rules

Config layers are additive, so a writable config file is a way to widen
`permissions` without touching the policy floor. The floor closes the three
places inside the container where an agent could otherwise write one:

| path | why it matters |
|---|---|
| `~/.config/opencode/*` | the server reads `opencode.json(c)` from here |
| `~/.cache/opencode/*` | the generated overlay lives here and is hot-reloaded |
| `/work/**/opencode.json`, `/work/**/.opencode/opencode.json` | project config merges over the global one |

`policies` cannot be loosened from any of them — the `/etc` layer is evaluated
last and a `deny` there is final — but `permissions` could be widened where no
policy speaks. Blocks are on `edit` plus `>` and `tee` for the cache, and on
`edit` for the project files. Editing a project's `opencode.json` by hand is
unaffected; only the agent is refused.

If a project genuinely needs the agent to edit its `opencode.json`, append an
`allow` for that one path *after* the deny in `policy/opencode.json`, and rebuild.

## What was blocked

The guardrails deny silently from inside the chat: a blocked command and a
broken one look the same. This reads them out of the server log.

```bash
./scripts/audit.sh          # last 24h
./scripts/audit.sh 7d       # 7d/2w work here though docker itself wants hours
```

It counts three kinds of denial — agent rules, the `/etc` policy layer, and
tool-level (`shell`, `read`, `edit`) — and prints the last eight entries. A
quiet week prints `nothing was blocked`, which is the honest answer, not a
guarantee that nothing tried.

## Kernel and filesystem hardening

Two layers sit below the OpenCode policy, because a policy is only as strong as
the process enforcing it.

**The root filesystem is read-only.** Nothing the agent writes survives in the
image: uploaded scripts, `crontab`, `~/.bashrc`, a replaced binary — all fail
with `Read-only file system`. Only these paths accept writes:

| Path | Kind | Purpose |
|---|---|---|
| `/work` | host bind (rw) | your projects |
| `/home/dev/.config` | tmpfs | rebuilt from the host config at every start |
| `/home/dev/.local/state` | tmpfs | service settings, re-applied at every start |
| `/home/dev/.local/share/opencode` | volume `oc-data` | sessions, credentials, snapshots |
| `/home/dev/.cache/opencode` | volume `oc-cache` | plugins, npm/pnpm cache |
| `/tmp` | tmpfs, `noexec` | scratch |

**seccomp refuses the escape primitives.** `seccomp/opencode.json` starts from
Docker's own default profile and removes 57 syscalls, then denies them with
`EPERM`: `mount`, `umount2`, `pivot_root`, `chroot`, `setns`, `unshare`,
`ptrace`, `process_vm_readv`/`writev`, `kcmp`, `bpf`, `perf_event_open`,
`userfaultfd`, `io_uring_*`, `keyctl`/`add_key`, `kexec_load`, `init_module`,
`open_by_handle_at`, `reboot`, `sethostname`, and friends. A normal Node build
keeps every syscall it needs; the acceptance suite proves both directions
(a file write to `/` fails, `ptrace` returns `EPERM`).

`seccomp/docker-default.json` is vendored from `moby/profiles`. To change the
deny list, edit `DENIED` in `scripts/gen-seccomp.mjs` and regenerate:

```bash
node scripts/gen-seccomp.mjs          # rewrite seccomp/opencode.json
node scripts/gen-seccomp.mjs --check  # exit 1 if it drifted
node --test tests/seccomp.test.mjs
```

**Images are pinned by digest,** not by tag, so a moved tag cannot swap the
content that runs. `node` is pinned in the `NODE_IMAGE` build arg, `nginx` in
`NGINX_IMAGE`; `scripts/check-updates.sh` prints the current pins and how to
obtain fresh digests.

## Known costs

- `browse` and the Chrome extension do not work inside the container.
- `context7` works only because the package is baked into the image.
- No SSH agent, git token, or `gh` inside: clone/fetch/push happen on the host.
  Projects are mounted read-write, so `.venv`, installs, builds and tests work.
- The agent can read the provider key files: it needs them to call the model.
- Docker is not a VM; the project mount is fully writable, so a hostile
  `package.json` still runs.
- Outbound internet is unrestricted; a leaked key is possible in principle.
- The root filesystem is read-only, so `apt-get install` inside the container
  fails by design. Add packages in the `Dockerfile` and rebuild.
- `/tmp` is `noexec`. A Playwright build (`INSTALL_PLAYWRIGHT=1`) may need
  `exec` on that tmpfs for Chromium's sandbox helper; swap `noexec` for `exec`
  in the `tmpfs` line if the browser refuses to start.

## Context7 rate limits

The `context7` MCP server runs inside the container. With no key it is
anonymous, so Context7 answers "using Context7 anonymously" and throttles.
Inside the container there is no browser to sign in with, and `npx ctx7 setup`
would rewrite a config that is regenerated on every start, so the key goes in
`.env` instead:

```bash
printf 'CONTEXT7_API_KEY=%s\n' 'YOUR_KEY' >> .env
./bin/oc up --build
docker logs opencode-docker-opencode-1 2>&1 | grep 'context7 will use'
```

`overlay.mjs` copies the key into the generated config's
`mcp.servers.context7.environment`, which is written `0600` into the `oc-cache`
volume.

## Backups

`oc-data` holds sessions, the stored account, and snapshots. Losing the volume
loses all of it, so back it up before upgrades and before `docker compose down -v`.

```bash
./scripts/backup.sh                 # writes ./backups/oc-data-<timestamp>.tar.gz (0600)
./scripts/restore.sh --check backups/oc-data-<timestamp>.tar.gz
```

Both scripts run as your own UID, inside the service user, so the volume and the
archive belong to you. If a backup fails with `Permission denied`, the volume
holds root-owned files from an older setup — recreate the container's data with
`sudo docker compose run --rm --user 0 --entrypoint sh opencode -c 'chown -R $HOST_UID:$HOST_GID /home/dev/.local/share/opencode'`
(needs the image built) and run the backup again.

Restore replaces the live volume, so it stops the container first and recreates
everything afterwards:

```bash
./scripts/restore.sh backups/oc-data-<timestamp>.tar.gz
sudo bash tests/acceptance.sh
```

The scripts run inside the project's own image, so they need no extra pull.
`backups/` is git-ignored.

### Weekly maintenance

`scripts/maintenance.sh` runs the checks that only matter over time: a fresh
backup, a readability check of it, `oc doctor`, `oc audit 7d`, and the pinned
version report. It never builds, starts or restores anything.

```bash
./scripts/maintenance.sh --dry-run    # print the steps, run nothing
sudo ./scripts/install-timer.sh       # weekly systemd timer, runs as root
sudo ./scripts/install-timer.sh --show   # see the generated units first
systemctl list-timers oc-maintenance.timer
journalctl -u oc-maintenance.service -n 40
```

The failure this catches: a backup that has been silently failing for weeks, or
an image that drifted away from `policy/` because somebody rebuilt without
`./bin/oc up --build`. It runs as root because the docker socket is root-only;
the archive itself is still written by the service user, so it stays yours.

`sudo ./scripts/install-timer.sh --remove` takes it away.

## Log growth

Every service has a `json-file` log limit (`max-size`, `max-file`), so a long
running stack cannot fill the disk. The OpenCode server's own log inside the
container is tailed by `docker logs`, so it is capped by the same setting.

## Egress

The container has unrestricted outbound access, which it needs for npm, git,
and the model endpoint. If you want a deterministic allowlist, run a proxy and
put it in `.env` (a compose `env_file`, so no edit to `docker-compose.yml`):

```bash
printf 'HTTPS_PROXY=http://127.0.0.1:3128\nHTTP_PROXY=http://127.0.0.1:3128\n' >> .env
sudo docker compose up -d --force-recreate
```

`NO_PROXY` stays `localhost,127.0.0.1,::1` so the container keeps talking to its
own server directly. OpenCode supports `HTTP_PROXY`, `HTTPS_PROXY`, `WS_PROXY`,
`WSS_PROXY`, and `ALL_PROXY`.

## /verify

The image ships a `verify` command (`commands/verify.md`), copied into the
container's command directory on every start. In a session type:

```
/verify
```

It runs the project's own type check, lint, and tests, and reports the real
output; it is not allowed to call work complete while a check is red.

## License

MIT. See [`LICENSE`](LICENSE).
