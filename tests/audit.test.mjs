import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, chmodSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// audit.sh converts windows that docker does not accept (7d, 2w) and must pass
// the result to `docker compose logs`. The shim records the argv instead of
// talking to a daemon, so this runs anywhere.
function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), "audit-"));
  mkdirSync(join(dir, "scripts"), { recursive: true });
  mkdirSync(join(dir, "shim"), { recursive: true });
  copyFileSync(new URL("../scripts/audit.sh", import.meta.url), join(dir, "scripts/audit.sh"));
  writeFileSync(join(dir, ".env"), "OPENCODE_PASSWORD=test\n");
  const log = join(dir, "calls.log");
  const shim = join(dir, "shim", "sudo");
  writeFileSync(shim, `#!/bin/sh\nprintf '%s\\n' "$*" >> "${log}"\nexit 1\n`);
  chmodSync(shim, 0o755);
  return { dir, log };
}

function run(dir, args) {
  return spawnSync("sh", [join(dir, "scripts/audit.sh"), ...args], {
    cwd: dir,
    env: { ...process.env, PATH: `${join(dir, "shim")}:${process.env.PATH}` },
    encoding: "utf8",
  });
}

function dockerArgs(log) {
  try {
    return readFileSync(log, "utf8").trim();
  } catch {
    return "";
  }
}

test("7d becomes 168h before docker sees it", () => {
  const { dir, log } = makeRepo();
  const r = run(dir, ["7d"]);
  assert.match(dockerArgs(log), /--since 168h opencode/);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /docker compose logs failed/);
});

test("2w becomes 336h", () => {
  const { dir, log } = makeRepo();
  run(dir, ["2w"]);
  assert.match(dockerArgs(log), /--since 336h opencode/);
});

test("docker durations pass through untouched", () => {
  const { dir, log } = makeRepo();
  run(dir, ["30m"]);
  assert.match(dockerArgs(log), /--since 30m opencode/);
});

test("an unknown unit is a usage error and never reaches docker", () => {
  const { dir, log } = makeRepo();
  const r = run(dir, ["7x"]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /not a window: 7x/);
  assert.equal(dockerArgs(log), "");
});

test("the default window is 24h", () => {
  const { dir, log } = makeRepo();
  run(dir, []);
  assert.match(dockerArgs(log), /--since 24h opencode/);
});
