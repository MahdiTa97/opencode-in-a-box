# OpenCode in Docker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the OpenCode server inside a hardened Docker container on this laptop, reachable only at `http://opencode.localhost:8080` through nginx, with the desktop app connected by a pairing link.

**Architecture:** Two compose services on one internal network: `opencode` (the managed OpenCode service as `dev`, no published ports) and `nginx` (the only published ports, loopback IPv4+IPv6). Config files are bind-mounted read-only over a writable config directory; the entrypoint regenerates a container-only config in the cache volume and starts the managed service.

**Tech Stack:** Docker Compose v5, `node:24-bookworm-slim`, `@opencode/cli` 2.3.0, nginx 1.27-alpine, Node's built-in test runner for the config generator.

**Spec:** `docs/superpowers/specs/2026-11-14-opencode-docker-design.md`

## Global Constraints

- Runtime version is pinned: `@opencode/cli@2.3.0`. Upgrades are an explicit edit.
- The container user is `dev`, UID/GID from `id -u` / `id -g` (currently 1000/1000).
- Never mount: the Docker socket, `$HOME`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `/run/user/*`, X11/Wayland sockets.
- Only published ports are `127.0.0.1:8080` and `[::1]:8080`.
- Everything that needs Docker runs as `sudo docker …` (socket is root-only); the agent cannot run those, the human does.
- `OPENCODE_PASSWORD` comes from `.env` (mode 600, git-ignored). No other credential.
- Basic auth username is always `opencode`.
- The baked policy is `/etc/opencode/opencode.json`, copied from the host's 31-statement file.

## Review Focus

- `OPENCODE_PASSWORD` unset or empty → the server must refuse to start, not start unauthenticated.
- Host config unreadable or malformed → the entrypoint must exit non-zero with the parse error, never fall back to defaults.
- Host config with no `context7` server entry → overlay must still be valid and drop `browse` only.
- Container restart → hostname, port, and password must stay the same (idempotent `service set`).
- A stale pairing link after restart → must not be presented as valid; only freshly minted links work.

---

### Task 1: Repository skeleton, `.env`, and a compose file that parses

**Files:**
- Create: `.gitignore`, `.env.example`, `.env` (600), `docker-compose.yml`, `README.md` (stub)

**Interfaces:**
- Produces: compose project name `opencode-docker`; service names `init`, `opencode`, `nginx`; network names `edge`, `egress`; volumes `oc-data`, `oc-cache`. Every later task refers to these exact names.

- [ ] **Step 1: Initialise the repository**

```bash
cd ~/opencode-docker && git init -b main
```

- [ ] **Step 2: Write `.gitignore`**

```
.env
*.log
```

- [ ] **Step 3: Write `.env.example` and `.env`**

`.env.example` holds `OPENCODE_PASSWORD=change-me` and commented `# HTTP_PROXY=`, `# HTTPS_PROXY=`, `# NO_PROXY=`. Copy to `.env`, replace the password with `openssl rand -base64 24`, `chmod 600 .env`.

- [ ] **Step 4: Write `docker-compose.yml`** with `init`, `opencode`, `nginx` services using `env_file: .env`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `init: true`, volumes `oc-data`/`oc-cache`, and the two published ports. Mounts, exactly as in the spec table: `~/.config/opencode` → `/home/dev/.config/opencode` rw, then `opencode.jsonc` and `opencode.json` as **ro single files** over it; the two key files individually ro; each project directory → `/work/<name>` rw.

- [ ] **Step 5: Verify it parses**

Run: `sudo docker compose config --quiet`
Expected: exit 0, no output. (Human runs this.)

- [ ] **Step 6: Commit**

```bash
git add .gitignore .env.example docker-compose.yml README.md
git commit -m "chore: compose skeleton and env template"
```

---

### Task 2: Image with the pinned CLI and the baked policy

**Files:**
- Create: `Dockerfile`, `policy/opencode.json`

**Interfaces:**
- Produces: image `opencode-docker-opencode:local`; user `dev` (UID/GID build args `UID`/`GID`); `/etc/opencode/opencode.json` from `policy/opencode.json`; `opencode` on `PATH`.

- [ ] **Step 1: Copy the host policy verbatim**

```bash
cp /etc/opencode/opencode.json ~/opencode-docker/policy/opencode.json
node -e 'console.log(JSON.parse(require("fs").readFileSync("policy/opencode.json","utf8")).policies.length)'
```

Expected: `31`.

- [ ] **Step 2: Write `Dockerfile`** — `FROM node:24-bookworm-slim`, apt install `git ripgrep curl ca-certificates jq python3 openssh-client`, `npm i -g @opencode/cli@2.3.0`, create `dev` with `--uid ${UID} --gid ${GID}`, `COPY policy/opencode.json /etc/opencode/opencode.json` with `root:root 644`, `USER dev`, `WORKDIR /work`.

- [ ] **Step 3: Build**

Run: `sudo docker compose build opencode`
Expected: image builds; the `npm i -g` layer reports `@opencode/cli@2.3.0`.

- [ ] **Step 4: Verify user and version inside the image**

Run: `sudo docker run --rm opencode-docker-opencode:local sh -c 'id; opencode --version; ls -l /etc/opencode/opencode.json'`
Expected: `uid=1000(dev)`, `opencode v2.3.0`, `-rw-r--r-- 1 root root`.

- [ ] **Step 5: Commit**

```bash
git add Dockerfile policy/opencode.json
git commit -m "feat: pinned image with baked policy layer"
```

---

### Task 3: Container config generator (pure function, unit-tested)

**Files:**
- Create: `overlay.mjs`, `tests/overlay.test.mjs`

**Interfaces:**
- Produces: `buildOverlay(sourceText, { context7Command }) -> string` (JSONC text) and CLI `node overlay.mjs <source> <dest>`. Later tasks call only the CLI.

- [ ] **Step 1: Write the failing tests** in `tests/overlay.test.mjs` using `node:test`:

```js
test("drops the browse server and keeps context7", ...)
test("rewrites the context7 command to the given absolute path", ...)
test("preserves providers, plugins, permissions and policies unchanged", ...)
test("throws on malformed JSONC with the parse position", ...)
test("keeps a valid file when the host has no mcp section", ...)
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `node --test tests/`
Expected: FAIL, `buildOverlay` not exported.

- [ ] **Step 3: Implement `buildOverlay`** — strip `//` line comments, `JSON.parse`, delete `mcp.servers.browse`, set `mcp.servers.context7.command` to `[context7Command]`, `JSON.stringify(…, null, 2)`; CLI writes the destination with mode `600` after `mkdir -p` of its directory. Throw `new Error(`invalid config: ${e.message}`)` on parse failure.

- [ ] **Step 4: Run the tests**

Run: `node --test tests/`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add overlay.mjs tests/overlay.test.mjs
git commit -m "feat: container config generator"
```

---

### Task 4: Entrypoint that starts the managed service

**Files:**
- Create: `entrypoint.sh`; Modify: `Dockerfile` (copy it, set `ENTRYPOINT`), `docker-compose.yml` (healthcheck)

**Interfaces:**
- Consumes: `overlay.mjs` CLI from Task 3.
- Produces: container that runs the managed service on `0.0.0.0:4097` with `OPENCODE_PASSWORD`; `docker logs` tails `~/.local/share/opencode/log/opencode.log`.

- [ ] **Step 1: Write `entrypoint.sh`** — `set -eu`; fail with `OPENCODE_PASSWORD is required` when unset or empty; generate the overlay to `~/.cache/opencode/container/opencode.jsonc`; export `OPENCODE_CONFIG`; run `opencode service set hostname 0.0.0.0`, `service set port 4097`, `service set password "$OPENCODE_PASSWORD"`, `service set env OPENCODE_PASSWORD "$OPENCODE_PASSWORD"`; `opencode service start`; `exec tail -F <log>`.

- [ ] **Step 2: Verify the fail-fast path** (no image rebuild needed)

Run: `sudo docker run --rm -e OPENCODE_PASSWORD= opencode-docker-opencode:local /entrypoint.sh; echo "exit=$?"`
Expected: message `OPENCODE_PASSWORD is required`, `exit=1`.

- [ ] **Step 3: Rebuild and start**

Run: `sudo docker compose up -d --build opencode && sudo docker compose logs --tail 20 opencode`
Expected: overlay written, service started, log tail visible.

- [ ] **Step 4: Verify auth and idempotency**

Run: `sudo docker compose exec opencode sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4097/api/info'` → `401`.
Run: `sudo docker compose restart opencode && sudo docker compose exec opencode opencode service status` → same port `4097`, service `running`.
Run: mint a link, restart, then request its token path through nginx — expected `4xx`: a link must not survive the restart that recreates the service state.

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh Dockerfile docker-compose.yml
git commit -m "feat: entrypoint starts the managed service"
```

---

### Task 5: nginx as the only published surface

**Files:**
- Create: `nginx/nginx.conf`; Modify: `docker-compose.yml` (nginx service, ports)

**Interfaces:**
- Produces: `http://127.0.0.1:8080` and `http://[::1]:8080` proxying to `http://opencode:4097`.

- [ ] **Step 1: Write `nginx/nginx.conf`** — `proxy_pass http://opencode:4097;`, `proxy_http_version 1.1`, `Upgrade`/`Connection` headers, `proxy_buffering off`, `proxy_read_timeout 3600s`, the four security headers, CSP in `Content-Security-Policy-Report-Only`, `limit_req` zones on `/auth/connect/`, `client_max_body_size 100m`.

- [ ] **Step 2: Wire the service** — image `nginx:1.27-alpine`, mount the conf read-only, `read_only: true` with tmpfs `/var/cache/nginx` and `/var/run`, depends_on `opencode`, ports `127.0.0.1:8080:8080` and `[::1]:8080:8080`.

- [ ] **Step 3: Start and verify the surface**

Run: `sudo docker compose up -d nginx`
Run: `curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/api/info` → `401`.
Run: `curl -g -s -o /dev/null -w "%{http_code}\n" http://[::1]:8080/api/info` → `401`.
Run: `curl -sI http://127.0.0.1:8080/ | grep -ciE "x-content-type-options|referrer-policy|x-frame-options|permissions-policy|content-security-policy-report-only"` → `5`.

- [ ] **Step 4: Verify the app password path works through nginx**

Run: `curl -s -u "opencode:$(grep ^OPENCODE_PASSWORD .env | cut -d= -f2-)" -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/api/info` → `200`.

- [ ] **Step 5: Commit**

```bash
git add nginx/nginx.conf docker-compose.yml
git commit -m "feat: nginx front door on loopback"
```

---

### Task 6: Acceptance script covering the spec's 12 tests

**Files:**
- Create: `tests/acceptance.sh`

**Interfaces:**
- Consumes: compose project, `overlay.mjs`, the image from Task 2.

- [ ] **Step 1: Write `tests/acceptance.sh`** — one function per spec acceptance test, each printing `PASS`/`FAIL` and a non-zero exit on any failure. Tests 1–7 and 10–12 run unattended; tests 8 and 9 print `MANUAL` and are recorded by the human (app pairing, CSP console).

- [ ] **Step 2: Run it**

Run: `sudo bash tests/acceptance.sh`
Expected: 10 `PASS`, 2 `MANUAL`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/acceptance.sh
git commit -m "test: acceptance suite for the container"
```

---

### Task 7: README and the human runbook

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document** start/stop/destroy/upgrade, the pairing command
  (`sudo docker compose exec opencode opencode pair --url http://opencode.localhost:8080`),
  where sessions live (`oc-data`), how to rotate the password, the proxy env
  vars, and the known costs copied from the spec. Add one line: after changing
  `/etc/opencode/opencode.json` on the host, re-copy it to `policy/opencode.json`
  and rebuild, or the container keeps the old rules.
- [ ] **Step 2: Verify every command in the README runs as written** in a fresh shell.
- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: runbook"
```
