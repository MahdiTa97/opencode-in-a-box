# Worktree Host Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make worktrees created by the container a normal git repository on the host, by pinning them inside the mounted tree and by teaching `oc doctor` to spot an installation where the host and container names for the tree differ.

**Architecture:** `overlay.mjs` builds the container config on every start; it now pins `worktree.directory` to `/work/.worktrees` unless the host sets a value. `bin/oc doctor` gains a ninth read-only check that compares `PROJECTS_DIR` with the mount target the container uses, and warns when they differ, because that difference is exactly what makes a worktree unreadable on the host.

**Tech Stack:** POSIX sh (`bin/oc`, 904 lines), Node 24 ESM (`overlay.mjs`), `node --test` for unit tests, JSONC config, Docker Compose.

**Spec:** `docs/superpowers/specs/2026-11-16-worktree-parity-design.md`

## Global Constraints

- Container path for the project tree is `/work`; the repo must never hardcode a personal host path.
- No second name for the tree inside the container (the policy matches on path strings).
- No locks and no self-written state: two operators may run any command concurrently.
- Builds only through `./bin/oc up --build`.
- Inside the container, `/tmp` is `noexec`, so tests must run as `TMPDIR=/work/.tmp node --test tests/*.test.mjs`.
- `bin/oc` is POSIX sh: no `[[ ]]`, no arrays, no `local` outside functions that already use it.
- `scripts/check-env.sh` is the single source of truth for `.env` rules; read values through it, never by parsing `.env` in `bin/oc`.

## Review Focus

- `PROJECTS_DIR=/work/projects` — a prefix of the target, not the target. Must WARN, not PASS (compare equality, not prefix).
- `PROJECTS_DIR=/work/` with a trailing slash — must PASS (normalise before comparing).
- `.env` missing or unreadable while `doctor` runs as root through sudo — check 9 must not crash or print a second failure for the same cause.
- `oc doctor --json` — check 9 must appear with `id: 9` and the counts must total nine.
- A host config that sets `worktree.directory` outside `/work` — the overlay must keep the host value and warn on stderr; it must never silently override.

---

### Task 1: Ship the worktree pinning that is already written

**Files:**
- Modify: `overlay.mjs:82-135` (already edited in the working tree)
- Test: `tests/overlay.test.mjs:120-151` (already written, four tests)

**Interfaces:**
- Consumes: nothing new.
- Produces: `buildConfig(sources, options)` where `options.worktreeDirectory` defaults to `"/work/.worktrees"` and `options.warn` is a `(message: string) => void` defaulting to a no-op; the returned `config.worktree` is `{ directory: string }`.

- [ ] **Step 1: Run the overlay tests and confirm 16 pass**

Run: `cd /work/oc-work && TMPDIR=/work/.tmp node --test tests/overlay.test.mjs`
Expected: `# pass 16` and `# fail 0`.

- [ ] **Step 2: Run the whole unit suite**

Run: `TMPDIR=/work/.tmp node --test tests/*.test.mjs`
Expected: `# pass 83`, `# fail 0`. If any test fails, stop and report before continuing.

- [ ] **Step 3: Commit**

```bash
git add overlay.mjs tests/overlay.test.mjs
git commit -m "fix: pin session worktrees inside the mounted project tree"
```

---

### Task 2: Add doctor check 9 (host path equals container path)

**Files:**
- Modify: `bin/oc:379-395` (`help_doctor`), `bin/oc:700-870` (`cmd_doctor`, insert after check 8, before the `JSON` output block)
- Test: `tests/oc.test.mjs` (append three tests; update the `--json` test at `tests/oc.test.mjs:505-514`)

**Interfaces:**
- Consumes: `sh scripts/check-env.sh get PROJECTS_DIR` → prints the value or exits non-zero; the helpers `pass ID TEXT`, `warn ID TEXT HINT [FIX]`, `fail ID TEXT HINT FIX` inside `cmd_doctor`.
- Produces: check id `9`, reading the target from `${OC_MOUNT_TARGET:-/work}` so the test suite and any installation that retargets the mount can compare against the right value; no other task depends on it.

- [ ] **Step 1: Write the three failing tests**

Append to `tests/oc.test.mjs`:

```js
test("doctor passes check 9 when the host path is the container path", () => {
  const dir = makeRepo();
  writeFileSync(path.join(dir, ".env"), "OPENCODE_PASSWORD=secret123\nHOST_HOME=/work\nPROJECTS_DIR=/work/\n");
  const r = oc(["doctor"], { repo: dir, env: { OC_MOUNT_TARGET: "/work", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /PASS 9 /, r.stdout);
});

test("doctor warns check 9 when the host path differs from the container path", () => {
  const dir = makeRepo();
  writeFileSync(path.join(dir, ".env"), "OPENCODE_PASSWORD=secret123\nHOST_HOME=/home/x\nPROJECTS_DIR=/home/x/projects\n");
  const r = oc(["doctor"], { repo: dir, env: { OC_MOUNT_TARGET: "/work", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /WARN 9 /, r.stdout);
  assert.match(r.stdout, /sudo mv/, r.stdout);
});

test("doctor warns check 9 for a directory below the mount target", () => {
  const dir = makeRepo();
  writeFileSync(path.join(dir, ".env"), "OPENCODE_PASSWORD=secret123\nHOST_HOME=/work\nPROJECTS_DIR=/work/projects\n");
  const r = oc(["doctor"], { repo: dir, env: { OC_MOUNT_TARGET: "/work", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /WARN 9 /, r.stdout);
});

test("doctor warns check 9 when PROJECTS_DIR is missing entirely", () => {
  const dir = makeRepo();
  writeFileSync(path.join(dir, ".env"), "OPENCODE_PASSWORD=secret123\nHOST_HOME=/work\n");
  const r = oc(["doctor"], { repo: dir, env: { OC_MOUNT_TARGET: "/work", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /WARN 9 /, r.stdout);
});
```

The first test writes `PROJECTS_DIR=/work/` and still expects PASS: that pins the trailing-slash normalisation. The fourth pins the missing-value case (a `.env` that never set it, so check 2 is the only other complaint). The third pins equality over prefix matching.

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `cd /work/oc-work && TMPDIR=/work/.tmp node --test --test-name-pattern='check 9' tests/oc.test.mjs`
Expected: FAIL — no `PASS 9` or `WARN 9` line is printed.

- [ ] **Step 3: Implement check 9 in `cmd_doctor`**

Insert after the check-8 block and before `if [ "$JSON" = 1 ]; then`:

```sh
  # 9. the host and the container use the same name for the tree
  # git stores absolute paths in a worktree's .git file; when the name differs
  # between host and container, the host cannot open what the container made.
  target=${OC_MOUNT_TARGET:-/work}
  projects=$(sh scripts/check-env.sh get PROJECTS_DIR 2>/dev/null || true)
  projects=${projects%/}
  if [ -z "$projects" ]; then
    warn 9 "PROJECTS_DIR is not set; cannot compare the host and container paths" "set it in .env" "oc config"
  elif [ "$projects" = "$target" ]; then
    pass 9 "host path equals the container path ($target); worktrees open on both sides"
  else
    warn 9 "PROJECTS_DIR is $projects but the container sees that tree at $target" \
      "worktrees created there are not git repositories on the host" \
      "sudo mv \"$projects\" $target && ln -s $target ~/projects"
  fi
```

- [ ] **Step 4: Run the three new tests to verify they pass**

Run: `TMPDIR=/work/.tmp node --test --test-name-pattern='check 9' tests/oc.test.mjs`
Expected: `# pass 4`, `# fail 0`.

- [ ] **Step 5: Update the `--json` test to nine checks**

In `tests/oc.test.mjs`, change `assert.equal(parsed.checks.length, 8)` to `9` and `assert.ok(parsed.passed + parsed.warned === 8)` to `=== 9`.

- [ ] **Step 6: Update the help text**

In `help_doctor`: `--json` line becomes "one JSON document: counts plus nine checks", the prose becomes "Nine read-only checks, exit 1 if any FAILs:", and the table gains `9 host path equals the container path` in the right-hand column of the last row, keeping the two-column alignment of the surrounding rows.

- [ ] **Step 7: Run the whole unit suite**

Run: `TMPDIR=/work/.tmp node --test tests/*.test.mjs`
Expected: `# pass 87`, `# fail 0`.

- [ ] **Step 8: Check the shell still parses, and read the check by eye**

Run: `dash -n bin/oc && echo ok`
Expected: `ok`.

- [ ] **Step 9: Commit**

```bash
git add bin/oc tests/oc.test.mjs
git commit -m "feat: warn when the host and container name the project tree differently"
```

---

### Task 3: Document the one-name rule

**Files:**
- Modify: `README.md` (Troubleshooting, new subsection after “The desktop app keeps starting its own local service”)
- Modify: `AGENTS.md` (pitfalls table, one new row; baked-vs-live table if it lists paths)
- Modify: `.env.example:19` (a comment above `PROJECTS_DIR`)

**Interfaces:**
- Consumes: the behaviour from Task 2 (check id 9, `OC_MOUNT_TARGET` default `/work`) and Task 1 (`/work/.worktrees`).
- Produces: no code interface.

- [ ] **Step 1: Add the README subsection**

Title: ``### `git` says a worktree is not a repository (on the host)``. Cover, in this order: the symptom (`fatal: not a git repository` for a directory that plainly exists), the cause (a worktree's `.git` file and `.git/worktrees/<name>/gitdir` hold absolute paths written where the worktree was created), the one-name rule, the migration block (`sudo mv` / `ln -s` / `chmod 750` / `PROJECTS_DIR=/work`), the check that it worked (`oc doctor` PASS 9), and the warning that `git worktree repair` must only be run from the spelling that will be used afterwards.

- [ ] **Step 2: Add the AGENTS.md pitfall row**

One row in the existing pitfalls table: symptom “a worktree the container created is not a git repository on the host”, cause “absolute container path inside the worktree's `.git` file”, fix “keep one name for the tree (`PROJECTS_DIR=/work`), see `oc doctor` check 9”.

- [ ] **Step 3: Annotate `.env.example`**

Above `PROJECTS_DIR=/home/you/projects`, one comment line: setting it to the same path the container uses (`/work`) is what lets the host open the worktrees the agent creates.

- [ ] **Step 4: Verify the docs render and nothing else broke**

Run: `git --no-pager diff --stat && TMPDIR=/work/.tmp node --test tests/*.test.mjs`
Expected: three files touched, `# pass 87`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add README.md AGENTS.md .env.example
git commit -m "docs: explain the one-name rule for worktrees shared with the host"
```

---

## Verification before handing back

- [ ] `dash -n bin/oc && bash -n tests/acceptance.sh && sh -n setup.sh scripts/*.sh entrypoint.sh`
- [ ] `TMPDIR=/work/.tmp node --test tests/*.test.mjs` → 87 pass, 0 fail
- [ ] `git --no-pager log --oneline -4` shows the three commits
- [ ] `git status --porcelain` is empty
- [ ] Hand the user the merge commands for `~/opencode-docker`
