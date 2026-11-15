import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const policy = JSON.parse(readFileSync(new URL("../policy/opencode.json", import.meta.url), "utf8"));
const statements = policy.policies;

test("policy file is a plain statement list", () => {
  assert.deepEqual(Object.keys(policy), ["policies"]);
  assert.ok(Array.isArray(statements));
  for (const s of statements) {
    assert.deepEqual(Object.keys(s).sort(), ["action", "effect", "resource"]);
    assert.equal(s.action, "tool.use");
    assert.ok(["allow", "deny"].includes(s.effect));
  }
});

test("every resource appears once", () => {
  const seen = new Set();
  for (const s of statements) {
    assert.ok(!seen.has(s.resource), `duplicate policy resource: ${s.resource}`);
    seen.add(s.resource);
  }
});

test("the only allow is the .env.example escape, and it comes after the .env denies", () => {
  const allows = statements.filter((s) => s.effect === "allow").map((s) => s.resource);
  assert.deepEqual(allows, ["edit:*.env.example"]);

  const lastEnvDeny = statements.findLastIndex((s) => s.effect === "deny" && s.resource === "edit:*.env.*");
  const allowAt = statements.findIndex((s) => s.resource === "edit:*.env.example");
  assert.ok(lastEnvDeny < allowAt, ".env.* deny must precede the .env.example allow (last match wins)");
});

test("writable config layers are closed", () => {
  const denied = new Set(statements.filter((s) => s.effect === "deny").map((s) => s.resource));
  for (const resource of [
    "edit:*.cache/opencode/*",
    "edit:*/.opencode/opencode.json",
    "shell:*>.cache/opencode/*",
  ]) {
    assert.ok(denied.has(resource), `missing deny: ${resource}`);
  }
});

test("the floor stays provider-agnostic", () => {
  for (const s of statements) {
    assert.ok(!/provider|model/.test(s.resource), `provider-specific policy: ${s.resource}`);
  }
});
