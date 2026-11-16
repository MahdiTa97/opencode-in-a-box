# Worktrees on the host: one name for one tree

Date: 2026-11-16
Status: approved

## Intent

OpenCode creates one git worktree per session. Two things go wrong with that
inside a container, and both are about *names*, not files:

1. By default the worktree lands in the server's data directory
   (`~/.local/share/opencode/worktree/<id>/<name>`), which is the `oc-data`
   volume. The host cannot see it at all.
2. Pinned inside `/work`, git writes absolute paths into the worktree's `.git`
   file and into `.git/worktrees/<name>/gitdir`. On the host those paths are
   `/work/...`, but the same tree is `~/projects/...` there. Git on the host
   says "not a git repository", so the branch the agent produced cannot be
   inspected, tested, or pushed from the machine the user actually works on.

The first is a configuration problem and is already solved. The second is the
subject of this design: **the same directory has two names, and tools store the
name, not the directory.**

## Goal

One name for the project tree on both sides, so that every tool (git, tsc,
eslint, VS Code, test runners) works on worktrees created by either side with no
translation step, no daemon, and no manual "flip the pointers" ritual.

## Non-goals

- Not a backup. Both sides still write to the same bytes; a container-side
  `rm` is a host-side `rm`. The weekly `oc backup` remains the only copy.
- Not Windows or macOS parity; this design is Linux-specific in its setup step.
- Not "push from inside the container". Mounting an SSH agent socket would let
  the sandbox use the user's keys, which is the opposite of the project's point.
- Not a reduction of the agent's blast radius. That trade-off was considered
  and rejected in favour of keep-it-simple; `git` is the safety net.

## Constraints

- **Portability.** The public repo must keep working for anyone whose projects
  live anywhere. Container path stays `/work`; nothing in the repo may hardcode
  a personal host path.
- **One spelling inside the container.** The policy floor matches on path
  strings (`/work/**`). Any second name for the same tree inside the container
  silently reopens every deny, so it is not allowed.
- **No locks, no self-written state.** Two operators must be able to run any
  `oc` command at the same time.
- **Build only through `./bin/oc up --build`.**

## Approaches considered

| | Approach | What it fixes | Cost | Verdict |
|---|---|---|---|---|
| الف | Accept: worktrees are container scratch, push the branch from the main repo on the host | nothing structural | zero | Works, but no host-side open/test of a worktree |
| هـ | git ≥2.48 `worktree.useRelativePaths` + `extensions.relativeWorktrees` | git only (layer 1 of 3) | image git upgrade **and** host git ≥2.48; the extension makes the repo unreadable for older git, including CI and colleagues | Rejected: blast radius larger than the feature |
| د | Mount the tree at its identical host path (`PROJECTS_ROOT`), policy rendered from a template | all layers | template the 53 policy statements, `bin/oc`, compose, acceptance tests, 15 recorded session directories | Rejected: a templating bug silently drops a rule |
| و / ح | Two spellings made valid on both sides (host alias, container alias) | all layers | reopens every `/work/**` deny inside the container | Rejected: security regression |
| **ج′** | **One name: the tree really lives at `/work`; `~/projects` becomes a symlink to it** | **all layers** | one host-side move, no repo code for the mapping | **Chosen** |

### Why ج′ wins

The kernel resolves a symlink, so `getcwd()` returns `/work/...` even when the
user enters through `~/projects`. There is therefore exactly one spelling in
existence, and it is the one the container already uses. Consequences:

- worktree pointers that already say `/work/...` become valid on the host
  immediately — no rewriting, no `git worktree repair`;
- nothing inside the container changes: same mount target, same policy, same
  sessions, no second name to dodge the floor;
- it survives reboot without an fstab entry (unlike a bind mount);
- `sudo mkdir /work` disappears: the `mv` creates the directory.

## The migration (user-run, once)

```bash
sudo mv /home/taala/projects /work
ln -s /work ~/projects
sudo chmod 750 /work
sed -i 's|^PROJECTS_DIR=.*|PROJECTS_DIR=/work|' ~/opencode-docker/.env
```

A running bind mount keeps working through the rename, so an already-running
container is unaffected; the next `oc up` recreates it from the new source.
`chmod 750` keeps the tree as private as it was inside a 750 home directory.

## What the repo has to do about it

1. **Pin worktrees inside the tree** (done, tested): `overlay.mjs` sets
   `worktree.directory` to `/work/.worktrees` when the host config leaves it
   unset, keeps a host value, and warns when the value points outside `/work` —
   because that is the silent version of this whole bug.
2. **Detect the split-name installation** (`oc doctor`, new check 9): read
   `PROJECTS_DIR` from `.env` and WARN when it is not `/work`, with the hint
   that worktrees created there will not be a git repository on the host, and
   the one-line fix. A warning, not a failure: a stranger's installation is
   perfectly valid, it just cannot open worktrees on the host.
3. **Document it** (README troubleshooting + AGENTS.md pitfall): the symptom
   ("not a git repository" for a directory that exists), the cause (absolute
   paths in `.git` pointers), the one-name rule, and the fact that `git worktree
   repair` must only ever be run from the same spelling.

## Left to the builder

- Exact wording, colour, and icon of check 9, matching the existing checks.
- Whether check 9 reads the value through `scripts/check-env.sh get` or by
  parsing `.env` — `check-env.sh` is the single source of truth for those rules,
  so use it if it answers the question without new cases.
- Test names and how many unit tests the new branch deserves.
- Whether `.worktrees` should be ignored in the project repos it serves (it is
  outside every repository, so nothing to ignore).
