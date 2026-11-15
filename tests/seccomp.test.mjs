import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build, DENIED } from "../scripts/gen-seccomp.mjs";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = JSON.parse(readFileSync(join(root, "seccomp", "docker-default.json"), "utf8"));
const committed = JSON.parse(readFileSync(join(root, "seccomp", "opencode.json"), "utf8"));

const allowed = (profile) =>
  new Set(
    profile.syscalls
      .filter((rule) => rule.action === "SCMP_ACT_ALLOW")
      .flatMap((rule) => rule.names),
  );
const denied = (profile) =>
  new Set(
    profile.syscalls
      .filter((rule) => rule.action === "SCMP_ACT_ERRNO")
      .flatMap((rule) => rule.names),
  );

test("fails closed: the default action is EPERM, not allow", () => {
  assert.equal(build(source).defaultAction, "SCMP_ACT_ERRNO");
});

test("every denied syscall is denied and none is still allowed", () => {
  const profile = build(source);
  const allow = allowed(profile);
  const deny = denied(profile);
  assert.ok(DENIED.length > 40, "deny list is unexpectedly short");
  for (const name of DENIED) {
    assert.ok(deny.has(name), `${name} is not denied`);
    assert.ok(!allow.has(name), `${name} is still allowed`);
  }
});

test("a JS/TS build keeps the syscalls it needs", () => {
  const allow = allowed(build(source));
  for (const name of [
    "execve", "execveat", "clone", "clone3", "fork", "vfork", "mmap",
    "openat", "read", "write", "socket", "connect", "sendto", "recvfrom",
    "sendmsg", "recvmsg", "futex", "epoll_wait", "newfstatat", "pipe2",
    "set_robust_list", "prctl", "getrandom", "statx",
  ]) {
    assert.ok(allow.has(name), `${name} must stay allowed`);
  }
});

test("the committed profile matches the generator", () => {
  assert.deepEqual(committed, build(source));
});

test("reference profiles are untouched apart from syscall filtering", () => {
  const profile = build(source);
  assert.equal(profile.archMap.length, source.archMap.length);
  // No rule may end up empty: Docker rejects names: [] entries.
  for (const rule of profile.syscalls) {
    assert.ok(rule.names.length > 0, `empty rule for action ${rule.action}`);
  }
});
