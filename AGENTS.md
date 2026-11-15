# AGENTS.md — working in this repository

This file is loaded automatically when OpenCode is opened with this directory as
the workspace. It records what this project expects from an agent, and the
non-obvious facts that cost real debugging time. Read `README.md` for the
user-facing runbook and `docs/superpowers/specs/` for the decisions behind it.

## What this is

A hardened way to run OpenCode on a personal Linux machine. One `docker compose`
project with three services:

- `init` — a one-shot root container that fixes volume ownership, then exits.
- `opencode` — the agent server, running as your UID/GID, no capabilities, no
  new privileges, read-only root filesystem, a seccomp profile that denies 57
  syscalls, and digest-pinned images.
- `nginx` — the only published surface: `127.0.0.1:8080` and `[::1]:8080`,
  HTTP Basic auth, rate-limited pairing endpoint.

Host configuration is never copied in wholesale. It is mounted read-only at
`/home/dev/host-config`, and `overlay.mjs` generates the container's own config
from it at every start.

## Non-negotiables

1. **`sudo` and `docker` are human-only.** The docker socket is `0600 root` and
   this user is not in the `docker` group. Never try to work around it; print
   the exact command for the human to run in a normal terminal.
2. **Build only with `./bin/oc up --build`.** It stamps the policy digest into
   the image. A plain `docker compose build` leaves the label `unknown`, and
   `oc doctor` check 6 will (correctly) complain.
3. **Never `--pull`.** Docker Hub returns 403 from this network. Pull
   `docker.arvancloud.ir/library/<image>` and retag, or pass
   `--build-arg NODE_IMAGE=…` / `NGINX_IMAGE=…` (see Troubleshooting).
4. **Know what is baked into the image.** Changing `Dockerfile`, `overlay.mjs`,
   `entrypoint.sh`, `commands/`, `policy/opencode.json` or
   `seccomp/opencode.json` has no effect until a rebuild. `bin/oc`, `scripts/`,
   `tests/`, `README.md` and `docs/` are read from the working tree and need no
   rebuild.
5. **Policy changes go through one file.** Edit `policy/opencode.json` only.
   Never edit `~/.config/opencode/opencode.jsonc` or `/etc/opencode/opencode.json`
   on someone's machine as a "fix"; print the `sudo install` line from the
   README instead. The floor is root-owned precisely so an agent cannot lift it.
6. **`ask` is inert in agent-driven sessions.** Verified empirically: a rule with
   `effect: ask` is treated as allow. Any rule that matters is `deny`.
7. **No new providers, plugins, or runtime dependencies.** This repository
   contains no provider names, by design; keep it that way in code, tests, docs
   and commit messages. Secrets never enter the tree: `.env` is `0600`,
   git-ignored, and only `.env.example` is committed.
8. **Two operators, one machine.** Every command here must be safe to run twice
   and safe to run from two terminals at once: no lock files, no caches, no
   hidden state. Destructive operations require an explicit `--yes`.

## Commands

| What | Command |
|---|---|
| Unit tests | `node --test tests/*.test.mjs` |
| Shell syntax | `dash -n bin/oc` · `sh -n setup.sh scripts/*.sh entrypoint.sh` · `bash -n tests/acceptance.sh` |
| Compose validity | `PROJECTS_DIR=… HOST_HOME=… docker compose config -q` |
| Build and start | `./bin/oc up --build` |
| Health of the installation | `./bin/oc doctor` (add `--json` for machines) |
| End-to-end checks | `sudo bash tests/acceptance.sh` (human) |
| What the guardrails blocked | `./bin/oc audit 24h` |
| Backup / verify | `./bin/oc backup` · `./bin/oc restore --check backups/<file>` |

## Invariants worth knowing before you change anything

- **Config layers are additive.** `OPENCODE_CONFIG` is merged *between* the
  global and project config, not used instead of them. That is why the host
  config is mounted at a non-global path: if it were mounted at
  `~/.config/opencode`, it would be the *global* layer and the overlay's
  deletions (dropping `browse`, dropping providers whose key file is absent)
  would never take effect.
- **The container config directory holds no `opencode.json(c)`.** `entrypoint.sh`
  copies `skills/`, `agents/`, `commands/` and `AGENTS.md` there, and that is all.
- **Two policy layers.** The image bakes `/etc/opencode/opencode.json`; the host
  may also have one. Broader configuration is evaluated later and wins, so a
  project cannot re-enable what the floor denies.
- **Seccomp is generated, never hand-edited.** `scripts/gen-seccomp.mjs` strips
  57 names out of Docker's default allowlist and appends one `ERRNO` rule.
  `node scripts/gen-seccomp.mjs --check` must stay green.
- **The root filesystem is read-only.** Writable: `/tmp`, `~/.config`,
  `~/.local/state`, and the volumes. If a tool needs another writable path, add
  a tmpfs or a volume; do not remove `read_only`.
- **Only `PROJECTS_DIR` is visible at `/work`.** Anything outside it is invisible
  to the container, on purpose.

## Pitfalls and their signatures

| Symptom | Cause | Fix |
|---|---|---|
| Acceptance passes but behaviour is old | image not rebuilt (`overlay.mjs`, `entrypoint.sh`, `commands/`, `policy/` are baked) | `./bin/oc up --build` |
| `npm error EEXIST /usr/local/bin/yarnpkg` | base image ships corepack shims | already handled: the install line removes them first |
| `EACCES: mkdir '/home/dev/.local/state'` | Docker creates volume parents as root | pre-created dev-owned in the `Dockerfile` |
| `EISDIR: illegal operation on a directory, read` | `sudo` sets `HOME=/root`, so `${HOME}` mounts pointed at `/root` | use `HOST_HOME` |
| Backups owned by root | a container running as root has no `DAC_OVERRIDE` under `cap_drop: ALL` | run `scripts/backup.sh` as the service user |
| `fatal: detected dubious ownership` | `git` run as root in a user-owned repo | `git -c safe.directory="$REPO"` |
| `sudo: The "no new privileges" flag is set` | desktop-app terminal sets `no_new_privs` | run docker commands in a normal terminal |
| nginx `502` after a restart | nginx resolved the upstream IP at start | recreate nginx (`oc restart` does) |
| App: `Failed to send prompt — Authentication required` | the app fell back to a host service on 4097 | re-pair with `./bin/oc pair`; see Troubleshooting |

## Definition of done

- `node --test tests/*.test.mjs` green, and every behaviour change arrived with a
  test that was watched failing first.
- Shell syntax checks above are clean; `docker compose config -q` parses.
- If a build input changed: the human has the rebuild + acceptance commands, and
  you have read the output they pasted back.
- `README.md` (and the matching spec) updated in the same commit as the change.
- No duplication: environment rules live in `scripts/check-env.sh`, command
  surfaces live in `bin/oc`, job logic lives in `scripts/*.sh`. If you need the
  same logic twice, move it into one of those and call it from both.
