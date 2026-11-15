import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, chmodSync, readFileSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const REPO = path.resolve(import.meta.dirname, "..");

// A shim records every call as "CALL <name>" followed by one "A <arg>" line per
// argument, so tests can assert argument boundaries (spaces in paths) as well as
// the command shape. Exit codes come from SHIM_<NAME>_EXIT, output from
// SHIM_<NAME>_OUT.
const SHIM = `#!/bin/sh
name=$(basename "$0")
{ printf 'CALL %s\n' "$name"; for a in "$@"; do printf 'A %s\n' "$a"; done; } >> "\${SHIM_LOG:?}"
case "$name" in
  docker)
    if [ "\${1:-}" = info ]; then
      if [ -n "\${SHIM_DOCKER_INFO_FAIL_UNLESS:-}" ]; then
        [ -f "\$SHIM_DOCKER_INFO_FAIL_UNLESS" ] && exit 0 || exit 1
      fi
      exit "\${SHIM_DOCKER_INFO_EXIT:-0}"
    fi
    if [ "\${1:-}" = compose ] && [ "\${2:-}" = ps ] && [ -n "\${SHIM_PS_OUT:-}" ]; then
      printf '%s\\n' "\$SHIM_PS_OUT"
    fi
    ;;
  sudo)
    if [ "\${SHIM_SUDO_EXEC:-0}" = 1 ]; then
      [ -n "\${SHIM_DOCKER_INFO_FAIL_UNLESS:-}" ] && : > "\$SHIM_DOCKER_INFO_FAIL_UNLESS"
      [ "\${1:-}" = -- ] && shift
      exec "\$@"
    fi
    ;;
  curl)
    if [ -n "\${SHIM_CURL_SEQ:-}" ]; then
      n=$(cat "\$SHIM_LOG.counter" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "\$n" > "\$SHIM_LOG.counter"
      printf '%s' "$(printf '%s\\n' "\$SHIM_CURL_SEQ" | sed -n "\${n}p")"
    else
      printf '%s' "\${SHIM_CURL_OUT:-000}"
    fi
    exit 0
    ;;
esac
exit "\${SHIM_EXIT:-0}"
`;

function makeShims() {
  const dir = mkdtempSync(path.join(tmpdir(), "oc-shim-"));
  for (const name of ["docker", "sudo", "curl", "git", "sha256sum"]) {
    if (name === "sha256sum") continue;
    const p = path.join(dir, name);
    writeFileSync(p, SHIM);
    chmodSync(p, 0o755);
  }
  return dir;
}

function makeRepo({ env, noEnv = false, scripts = {} } = {}) {
  const dir = mkdtempSync(path.join(tmpdir(), "oc-repo-"));
  mkdirSync(path.join(dir, "bin"));
  mkdirSync(path.join(dir, "scripts"));
  mkdirSync(path.join(dir, "policy"));
  mkdirSync(path.join(dir, "seccomp"));
  copyFileSync(path.join(REPO, "bin", "oc"), path.join(dir, "bin", "oc"));
  chmodSync(path.join(dir, "bin", "oc"), 0o755);
  copyFileSync(path.join(REPO, "docker-compose.yml"), path.join(dir, "docker-compose.yml"));
  copyFileSync(path.join(REPO, "policy", "opencode.json"), path.join(dir, "policy", "opencode.json"));
  copyFileSync(path.join(REPO, "seccomp", "opencode.json"), path.join(dir, "seccomp", "opencode.json"));
  copyFileSync(path.join(REPO, "scripts", "check-env.sh"), path.join(dir, "scripts", "check-env.sh"));
  for (const [name, body] of Object.entries(scripts)) {
    const p = path.join(dir, "scripts", name);
    writeFileSync(p, body);
    chmodSync(p, 0o755);
  }
  if (!noEnv) {
    writeFileSync(
      path.join(dir, ".env"),
      env ??
        "OPENCODE_PASSWORD=secret123\nHOST_UID=1000\nHOST_GID=1000\nHOST_HOME=/home/x\nPROJECTS_DIR=/home/x/projects\n"
    );
    chmodSync(path.join(dir, ".env"), 0o600);
  }
  return dir;
}

function oc(args, { repo, env = {}, cwd, entry } = {}) {
  const root = repo ?? makeRepo();
  const shims = makeShims();
  const log = path.join(shims, "log");
  writeFileSync(log, "");
  const res = spawnSync(entry ? path.resolve(root, entry) : path.join(root, "bin", "oc"), args, {
    cwd: cwd ?? root,
    encoding: "utf8",
    env: {
      ...process.env,
      PATH: `${shims}:${process.env.PATH}`,
      SHIM_LOG: log,
      ...env,
    },
  });
  return {
    code: res.status,
    stdout: res.stdout ?? "",
    stderr: res.stderr ?? "",
    calls: readFileSync(log, "utf8"),
    repo: root,
  };
}

const hasCall = (calls, prog, ...args) =>
  calls.includes(`CALL ${prog}\n`) && args.every((a) => calls.includes(`A ${a}\n`));

test("help lists every command", () => {
  const r = oc(["help"]);
  assert.equal(r.code, 0);
  for (const cmd of ["up", "down", "restart", "status", "pair", "shell", "logs", "backup", "restore", "audit", "config", "doctor"]) {
    assert.match(r.stdout, new RegExp(`\\b${cmd}\\b`), `help must mention ${cmd}`);
  }
});

test("unknown command is a usage error", () => {
  const r = oc(["nonsense"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown command: nonsense/);
});

test("resolves the repo from the script path, not the caller's cwd", () => {
  const elsewhere = mkdtempSync(path.join(tmpdir(), "oc-cwd-"));
  const r = oc(["status"], { cwd: elsewhere });
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "ps"), r.calls);
});

test("re-execs through sudo when the daemon is unreachable", () => {
  const r = oc(["status"], { env: { SHIM_DOCKER_INFO_EXIT: "1" } });
  assert.equal(r.code, 0);
  assert.match(r.calls, /CALL sudo\n/);
  assert.match(r.calls, /A status\n/);
});

test("OC_NO_SUDO=1 explains instead of prompting", () => {
  const r = oc(["status"], { env: { SHIM_DOCKER_INFO_EXIT: "1", OC_NO_SUDO: "1" } });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /docker group/);
  assert.doesNotMatch(r.calls, /CALL sudo\n/);
});

test("up waits for health", () => {
  const r = oc(["up"]);
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "up", "-d", "--wait", "--wait-timeout", "90"), r.calls);
});

test("up --build stamps the policy digest", () => {
  const r = oc(["up", "--build"]);
  assert.equal(r.code, 0);
  assert.match(r.calls, /A --build-arg\nA POLICY_SHA=[0-9a-f]{64}\n/);
  assert.ok(hasCall(r.calls, "docker", "compose", "up", "-d", "--wait", "--wait-timeout", "90"), r.calls);
});

test("up is idempotent", () => {
  const repo = makeRepo();
  const first = oc(["up"], { repo });
  const second = oc(["up"], { repo });
  assert.equal(first.code, 0);
  assert.equal(second.code, 0);
  // Both invocations ran the same converge command, and neither recreated
  // containers that were already current.
  for (const run of [first, second]) {
    assert.ok(hasCall(run.calls, "docker", "compose", "up", "-d", "--wait", "--wait-timeout", "90"));
    assert.equal(run.calls.split("A up\n").length - 1, 1);
    assert.doesNotMatch(run.calls, /--force-recreate/);
    assert.doesNotMatch(run.calls, /A down/);
  }
});

test("down refuses --volumes without --yes, and touches nothing", () => {
  const r = oc(["down", "--volumes"]);
  assert.equal(r.code, 1);
  assert.match(r.stderr, /--yes/);
  assert.equal(r.calls.trim(), "");
});

test("down --volumes --yes proceeds", () => {
  const r = oc(["down", "--volumes", "--yes"]);
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "down", "--volumes"), r.calls);
});

test("restart recreates rather than restarting", () => {
  const r = oc(["restart"]);
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "up", "-d", "--force-recreate", "--wait", "--wait-timeout", "90"), r.calls);
});

test("pair mints a link through the service", () => {
  const r = oc(["pair"]);
  assert.equal(r.code, 0);
  assert.ok(
    hasCall(r.calls, "docker", "compose", "exec", "-T", "opencode", "opencode", "pair", "--url", "http://opencode.localhost:8080"),
    r.calls
  );
});

test("shell defaults to bash and forwards a command line", () => {
  const bare = oc(["shell"]);
  assert.ok(hasCall(bare.calls, "docker", "compose", "exec", "opencode", "bash"), bare.calls);
  const cmd = oc(["shell", "ls", "-l"]);
  assert.ok(hasCall(cmd.calls, "docker", "compose", "exec", "opencode", "sh", "-lc", "ls -l"), cmd.calls);
});

test("logs forwards -f and --since", () => {
  const r = oc(["logs", "-f", "--since", "2h"]);
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "logs", "-f", "--since", "2h", "opencode"), r.calls);
});

test("backup forwards a destination with spaces as one argument", () => {
  const repo = makeRepo({
    scripts: { "backup.sh": '#!/bin/sh\n{ echo CALL backup; for a in "$@"; do echo "A $a"; done; } >> "$SHIM_LOG"\n' },
  });
  const r = oc(["backup", "/tmp/my backups"], { repo });
  assert.equal(r.code, 0);
  assert.match(r.calls, /A \/tmp\/my backups\n/);
});

test("restore --check forwards the archive", () => {
  const repo = makeRepo({
    scripts: { "restore.sh": '#!/bin/sh\n{ echo CALL restore; for a in "$@"; do echo "A $a"; done; } >> "$SHIM_LOG"\n' },
  });
  const r = oc(["restore", "--check", "backups/x.tar.gz"], { repo });
  assert.equal(r.code, 0);
  assert.match(r.calls, /A --check\nA backups\/x\.tar\.gz\n/);
});

test("restore without --yes refuses", () => {
  const repo = makeRepo({
    scripts: { "restore.sh": '#!/bin/sh\n{ echo CALL restore; } >> "$SHIM_LOG"\n' },
  });
  const r = oc(["restore", "backups/x.tar.gz"], { repo });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /--yes/);
});

test("audit forwards the window", () => {
  const repo = makeRepo({
    scripts: { "audit.sh": '#!/bin/sh\n{ echo CALL audit; for a in "$@"; do echo "A $a"; done; } >> "$SHIM_LOG"\n' },
  });
  const r = oc(["audit", "7d"], { repo });
  assert.equal(r.code, 0);
  assert.match(r.calls, /A 7d\n/);
});

test("config names the missing variable", () => {
  const repo = makeRepo({ env: "OPENCODE_PASSWORD=secret123\nHOST_HOME=/home/x\n" });
  const r = oc(["config"], { repo });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /PROJECTS_DIR/);
});

test("config accepts a complete env", () => {
  const r = oc(["config"]);
  assert.equal(r.code, 0);
  assert.ok(hasCall(r.calls, "docker", "compose", "config", "-q"), r.calls);
});

test("doctor reports missing .env and exits 1", () => {
  const repo = makeRepo();
  spawnSync("rm", ["-f", path.join(repo, ".env")]);
  const r = oc(["doctor"], { repo });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /FAIL 1 /);
});

test("doctor passes the environment checks on a valid repo", () => {
  const dir = makeRepo();
  mkdirSync(path.join(dir, "projects"), { recursive: true });
  // PROJECTS_DIR must point at a real directory for the check to pass
  writeFileSync(
    path.join(dir, ".env"),
    `OPENCODE_PASSWORD=secret123\nHOST_UID=1000\nHOST_GID=1000\nHOST_HOME=${dir}\nPROJECTS_DIR=${dir}/projects\n`
  );
  const r = oc(["doctor"], { repo: dir });
  assert.match(r.stdout, /PASS 1 /);
  assert.match(r.stdout, /PASS 2 /);
  assert.match(r.stdout, /PASS 3 /);
});

test("doctor fails when nginx does not answer 401", () => {
  const dir = makeRepo();
  mkdirSync(path.join(dir, "projects"), { recursive: true });
  writeFileSync(
    path.join(dir, ".env"),
    `OPENCODE_PASSWORD=secret123\nHOST_UID=1000\nHOST_GID=1000\nHOST_HOME=${dir}\nPROJECTS_DIR=${dir}/projects\n`
  );
  const r = oc(["doctor"], { repo: dir, env: { SHIM_curl_OUT: "200" } });
  assert.match(r.stdout, /FAIL 7 /);
});

test("doctor warns when the host floor is absent", () => {
  const dir = makeRepo();
  mkdirSync(path.join(dir, "projects"), { recursive: true });
  writeFileSync(
    path.join(dir, ".env"),
    `OPENCODE_PASSWORD=secret123\nHOST_UID=1000\nHOST_GID=1000\nHOST_HOME=${dir}\nPROJECTS_DIR=${dir}/projects\n`
  );
  const r = oc(["doctor"], { repo: dir, env: { SHIM_curl_OUT: "401", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /WARN 8 /);
});

test("the Dockerfile carries the policy digest label", () => {
  const dockerfile = readFileSync(path.join(REPO, "Dockerfile"), "utf8");
  assert.match(dockerfile, /LABEL org\.opencode-docker\.policy-sha=/);
  assert.match(readFileSync(path.join(REPO, "bin", "oc"), "utf8"), /--build-arg/);
});

test("doctor passes check 7 on a healthy install", () => {
  const repo = makeRepo();
  const r = oc(["doctor"], {
    repo,
    env: { SHIM_PS_OUT: "opencode healthy", SHIM_CURL_OUT: "401", OC_FLOOR: "/nonexistent/floor.json" },
  });
  assert.match(r.stdout, /PASS 7 service healthy; both loopback addresses answer 401/, r.stdout);
});

test("doctor fails check 7 when only one loopback address answers 401", () => {
  const repo = makeRepo();
  const r = oc(["doctor"], {
    repo,
    env: {
      SHIM_PS_OUT: "opencode healthy",
      SHIM_CURL_SEQ: "401\n502",
      OC_FLOOR: "/nonexistent/floor.json",
    },
  });
  assert.match(r.stdout, /FAIL 7 nginx answered 502 on \[::1\]:8080/, r.stdout);
});

test("the sudo re-exec keeps the command and its arguments", () => {
  const repo = makeRepo();
  const marker = path.join(mkdtempSync(path.join(tmpdir(), "oc-root-")), "daemon-ok");
  const r = oc(["logs", "-f", "--since", "2h"], {
    repo,
    env: { SHIM_DOCKER_INFO_FAIL_UNLESS: marker, SHIM_SUDO_EXEC: "1" },
  });
  assert.equal(r.code, 0, r.stderr);
  assert.ok(r.calls.includes("CALL sudo\n"), r.calls);
  assert.ok(hasCall(r.calls, "docker", "compose", "logs", "-f", "--since", "2h", "opencode"), r.calls);
});

test("a symlinked oc still finds the repo", () => {
  const repo = makeRepo();
  const link = path.join(mkdtempSync(path.join(tmpdir(), "oc-link-")), "oc");
  symlinkSync(path.join(repo, "bin", "oc"), link);
  const res = spawnSync(link, ["version"], { encoding: "utf8" });
  assert.match(res.stdout, new RegExp(`repo ${repo.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`), res.stdout);
});

test("a relative invocation still finds the repo", () => {
  const repo = makeRepo();
  const res = spawnSync("./oc", ["version"], { cwd: path.join(repo, "bin"), encoding: "utf8" });
  assert.match(res.stdout, new RegExp(`repo ${repo.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`), res.stdout);
});

test("doctor fails check 8 when the host floor changed but kept the count", () => {
  const repo = makeRepo();
  const floor = path.join(mkdtempSync(path.join(tmpdir(), "oc-floor-")), "floor.json");
  const text = readFileSync(path.join(repo, "policy", "opencode.json"), "utf8");
  writeFileSync(floor, text.replace('"deny"', '"allow"'));
  const r = oc(["doctor"], { repo, env: { OC_FLOOR: floor, SHIM_PS_OUT: "opencode healthy", SHIM_CURL_OUT: "401" } });
  assert.match(r.stdout, /FAIL 8 host floor differs/, r.stdout);
});

test("doctor fails check 5 when the seccomp profile drifts", () => {
  const repo = makeRepo({ scripts: { "gen-seccomp.mjs": "process.exit(1);\n" } });
  const r = oc(["doctor"], { repo, env: { OC_FLOOR: "/nonexistent/floor.json", SHIM_PS_OUT: "opencode healthy", SHIM_CURL_OUT: "401" } });
  assert.match(r.stdout, /FAIL 5 seccomp profile is stale/, r.stdout);
});

test("doctor still reports the offline checks when docker is unreachable", () => {
  const repo = makeRepo();
  const r = oc(["doctor"], { repo, env: { OC_NO_SUDO: "1", SHIM_DOCKER_INFO_EXIT: "1", OC_FLOOR: "/nonexistent/floor.json" } });
  assert.match(r.stdout, /PASS 1 /, r.stdout);
  assert.match(r.stdout, /WARN 3 docker daemon unreachable/, r.stdout);
  assert.match(r.stdout, /WARN 7 docker daemon unreachable/, r.stdout);
  assert.doesNotMatch(r.stdout, /FAIL /, r.stdout);
  assert.equal(r.code, 0, r.stdout);
});

test("commands without options reject stray arguments", () => {
  for (const cmd of ["restart", "status", "pair", "version"]) {
    const r = oc([cmd, "typo"]);
    assert.equal(r.code, 2, `${cmd} must reject arguments`);
    assert.match(r.stderr, /takes no arguments/);
    assert.doesNotMatch(r.calls, /CALL docker/);
  }
});

test("restore accepts exactly one archive", () => {
  const r = oc(["restore", "a.tar.gz", "b.tar.gz", "--yes"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /one archive/);
  assert.doesNotMatch(r.calls, /CALL sh/);
});

test("logs keeps a window that contains spaces as one argument", () => {
  const repo = makeRepo({ scripts: {} });
  const r = oc(["logs", "--since", "2 hours"], { repo, env: { SHIM_DOCKER_INFO_EXIT: "0" } });
  assert.equal(r.code, 0);
  assert.match(r.calls, /CALL docker\n(?:A [^\n]*\n)*A --since\nA 2 hours\nA opencode\n/);
});

test(".env values with spaces are accepted, not reported as missing", () => {
  const repo = makeRepo({
    env: "OPENCODE_PASSWORD=secret123\nHOST_HOME=/home/x\nPROJECTS_DIR=/tmp/oc with space\n",
  });
  mkdirSync("/tmp/oc with space", { recursive: true });
  const res = spawnSync("sh", [path.join(repo, "scripts", "check-env.sh"), "paths"], {
    cwd: repo,
    encoding: "utf8",
  });
  assert.equal(res.status, 0, res.stdout);
});

test("a piped command emits no escape sequences", () => {
  const r = oc(["help"]);
  assert.equal(r.code, 0);
  assert.doesNotMatch(r.stdout, /\u001b\[/);
});

test("OC_ASCII uses plain icons even on a UTF-8 terminal", () => {
  const r = oc(["doctor"], { env: { OC_ASCII: "1", OC_NO_SUDO: "1" } });
  assert.doesNotMatch(r.stdout, /[✓✗]/);
  assert.match(r.stdout, /^(PASS|WARN|FAIL) [0-9] /m);
});

test("oc help up prints that command's own help", () => {
  const r = oc(["help", "up"]);
  assert.equal(r.code, 0);
  assert.match(r.stdout, /usage: oc up/);
  assert.match(r.stdout, /--build/);
  assert.match(r.stdout, /oc up --build/);
});

test("up --help is the same page as oc help up", () => {
  const a = oc(["help", "up"]);
  const b = oc(["up", "--help"]);
  assert.equal(b.code, 0);
  assert.equal(b.stdout, a.stdout);
  assert.equal(b.calls, "");
});

test("a near-miss command suggests the real one", () => {
  const r = oc(["stauts"]);
  assert.equal(r.code, 2);
  assert.match(r.stderr, /did you mean: status\?/);
});

test("a bad flag is a usage error before sudo", () => {
  const r = oc(["up", "--nope"], { env: { SHIM_DOCKER_INFO_EXIT: "1" } });
  assert.equal(r.code, 2);
  assert.match(r.stderr, /unknown option for up: --nope/);
  assert.doesNotMatch(r.calls, /CALL sudo/);
});

test("a flag without its value is caught before docker", () => {
  const r = oc(["logs", "--since"], { env: { SHIM_DOCKER_INFO_EXIT: "1" } });
  assert.equal(r.code, 2);
  assert.match(r.stderr, /--since needs a value/);
  assert.doesNotMatch(r.calls, /CALL docker/);
});

test("a missing .env names the fix", () => {
  const repo = makeRepo({ noEnv: true });
  const r = oc(["up"], { repo, env: { OC_NO_SUDO: "1" } });
  assert.equal(r.code, 1);
  assert.match(r.stderr, /setup\.sh/);
  assert.doesNotMatch(r.calls, /CALL docker/);
});

test("doctor --json is machine readable", () => {
  const r = oc(["doctor", "--json"], { env: { OC_NO_SUDO: "1" } });
  const parsed = JSON.parse(r.stdout);
  assert.equal(parsed.checks.length, 8);
  assert.ok(parsed.passed + parsed.warned + parsed.failed === 8);
  for (const c of parsed.checks) {
    assert.ok(["1", "2", "3", "4", "5", "6", "7", "8"].includes(String(c.id)), c.id);
    assert.ok(["pass", "warn", "fail"].includes(c.status), c.status);
  }
});

test("doctor carries a fix line on a failing check", () => {
  const repo = makeRepo({ noEnv: true });
  const r = oc(["doctor"], { repo, env: { OC_NO_SUDO: "1" } });
  assert.equal(r.code, 1);
  assert.match(r.stdout, /fix: .*setup\.sh/);
});
