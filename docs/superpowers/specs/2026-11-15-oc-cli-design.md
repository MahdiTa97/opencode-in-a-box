# `oc` — a single entry point for the container (design)

Date: 2026-11-15
Status: approved by the user in conversation ("تایید پیشنهاد انجام ۱ و ۲")

## Intent

Running this project today means remembering long `sudo docker compose …`
invocations for eleven different jobs, and remembering which of them need a
rebuild afterwards. Three times during this project an image was stale because
the rebuild step was forgotten, and once the container would not start because
the kernel lacked seccomp. Both failures were discoverable in seconds by a
check nobody ran.

`oc` is a thin wrapper with two halves: shortcuts for the daily commands, and
`oc doctor`, which answers "is this installation actually in the state its
files claim?".

## Goals

- One command per routine job, discoverable from `oc help`.
- `oc doctor` reports the seven failure modes that have actually bitten this
  project, each as PASS / WARN / FAIL, exiting non-zero on any FAIL.
- No duplicated logic: every job delegates to the script or compose invocation
  that already owns it.
- Two people, or two terminals, can run any `oc` subcommand at the same time
  without corrupting state.
- Works on a machine with no docker group (re-execs through `sudo`).

## Non-goals

- Not a replacement for `docker compose`; `oc` does not implement anything the
  compose file does not already express.
- No `oc upgrade`, no `oc export/import` (deferred in the same conversation).
- No state of its own: no lock files, no caches, no config. Everything it reads
  is `.env`, the compose file, the repo, or docker itself.

## Anti-goals

- An `oc` that hides what it runs. Every docker call is printed as `+ …` when
  `OC_VERBOSE=1`, and `oc doctor` never mutates anything.
- An `oc` that needs a build step or a dependency. It is POSIX `sh`, like every
  other script in `scripts/`.

## Approaches considered

**A. Extend each `scripts/*.sh` and document a table in the README.** Cheapest
to write, but the user still types `sudo docker compose` for the six jobs that
have no script, which is the actual friction.

**B. A `Makefile`.** Idiomatic for build targets, awkward for argument passing
(`make pair` cannot take `--url`), and it hides the real command less than it
hides the fact that half the targets are `sudo docker compose` one-liners.

**C. One `bin/oc` dispatcher, delegating to existing scripts (chosen).** Matches
the way the project is already organised (one file per job under `scripts/`),
keeps every command visible in `oc help`, and gives `doctor` a natural home next
to the checks it runs.

## Design

`bin/oc`, POSIX `sh`, executable, resolves the repo root from its own path, so
it works from any directory. Dispatch table:

| command | runs |
|---|---|
| `oc up [--build]` | `docker compose up -d --wait --wait-timeout 90` |
| `oc down [--volumes] [--yes]` | `docker compose down`; refuses `--volumes` without `--yes` |
| `oc restart` | `docker compose up -d --force-recreate` (idempotent, keeps volumes) |
| `oc status` | `docker compose ps` + health of `opencode` and `nginx` |
| `oc pair` | `docker compose exec opencode opencode pair --url http://opencode.localhost:8080` |
| `oc shell [cmd…]` | `docker compose exec opencode sh -lc <cmd>` (default: `bash`) |
| `oc logs [-f] [--since W]` | `docker compose logs opencode` |
| `oc backup [dir]` | `scripts/backup.sh` |
| `oc restore --check FILE` / `oc restore FILE --yes` | `scripts/restore.sh` |
| `oc audit [window]` | `scripts/audit.sh` |
| `oc config` | `.env` sanity + `docker compose config -q` |
| `oc doctor` | checks below |
| `oc version`, `oc help` | no docker |

Every command runs from the repo root. `sudo` handling lives in one function:
if `docker info` fails, re-run the whole command line under `sudo` (preserving
arguments) unless `OC_NO_SUDO=1`, in which case it explains what is missing and
exits 1.

### `oc doctor` checks

| # | check | FAIL when | WARN when |
|---|---|---|---|
| 1 | `.env` exists, mode 600 | missing, unreadable, or `OPENCODE_PASSWORD` empty/`change-me` | mode is not 600 |
| 2 | `HOST_HOME`, `PROJECTS_DIR` set; `PROJECTS_DIR` exists and is writable | unset, or `PROJECTS_DIR` is `/` or `$HOME` | path does not exist (compose will still start) |
| 3 | `docker compose config -q` | invalid | — |
| 4 | image is current | image is older than the newest commit touching `Dockerfile`, `overlay.mjs`, `entrypoint.sh`, `commands/`, `policy/`, `seccomp/` | — |
| 5 | seccomp profile matches its generator | `node scripts/gen-seccomp.mjs --check` is non-zero | node missing |
| 6 | baked policy matches `policy/opencode.json` | label digest in the image differs from the file | label absent (image predates the label) |
| 7 | `opencode` service healthy and nginx answers 401 on both loopback addresses | service not running/unhealthy, or a 200/000 | IPv6 address unreachable (host without IPv6) |
| 8 | host floor `/etc/opencode/opencode.json` matches the repo policy | file exists and differs | file missing, or unreadable |

Check 4 needs the image's build time, which compose records on the image, and
the commit time of the newest relevant file from git. Check 6 needs a digest of
the policy recorded at build time; the `Dockerfile` gains one `LABEL` whose
value is the sha256 of `policy/opencode.json`, so the comparison needs no
`docker run` and no sudo beyond `docker image inspect`.

### Concurrency

Every subcommand is read-only or idempotent, and none writes a file that another
could be writing:

- `up`/`restart` converge: compose serialises container recreation.
- `down --volumes` requires `--yes`, so it cannot happen by accident from a
  cron job or a second terminal.
- `backup` already names archives by timestamp (`scripts/backup.sh`), so two
  runs produce two files.
- `doctor`, `status`, `config` never write.

## What is left to the builder

- Exact wording of the help text and the doctor table.
- Whether `oc shell` defaults to `bash` (present in the image) or `sh`.
- The `LABEL` name in the `Dockerfile` (`org.opencode-docker.policy-sha`).
- Test fixtures: a fake `docker`/`curl`/`git`/`sudo` on `PATH`, the pattern
  already proven for `scripts/audit.sh`.

## Acceptance

`tests/oc.test.mjs` (node:test, no docker daemon):

- `oc help` exits 0 and lists every command in the table.
- `oc nonsense` exits 2 and prints usage on stderr.
- `oc up` invokes `docker compose up -d --wait --wait-timeout 90`; `--build`
  adds `--build`.
- `oc down --volumes` without `--yes` exits 1 and calls nothing.
- `oc audit 7d` passes the window to `scripts/audit.sh`.
- `docker info` failing makes `oc status` re-exec through the `sudo` shim.
- `OC_NO_SUDO=1` with a failing daemon exits 1 and names the missing group.
- `oc doctor` in a temporary repo with no `.env` reports FAIL for check 1 and
  exits 1.
- `oc doctor` passes checks 1–3 in a temporary repo with a valid `.env`.
- The `Dockerfile` carries the policy-sha label.

`tests/acceptance.sh` gains one check: the label in the running image equals
`sha256sum policy/opencode.json`.
