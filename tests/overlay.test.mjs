import test from "node:test";
import assert from "node:assert/strict";
import { buildOverlay } from "../overlay.mjs";

const HOST_CONFIG = `{
  // host-only comment
  "providers": { "gateway": { "settings": { "apiKey": "{file:~/.secrets/gateway.key}" } } },
  "mcp": {
    "servers": {
      "context7": { "type": "local", "command": ["/home/you/.config/opencode/context7-mcp.sh"] },
      "browse": { "type": "local", "command": ["/usr/local/bin/browse", "mcp"] }
    }
  },
  "permissions": [{ "action": "edit", "resource": "*.env", "effect": "deny" }],
  "policies": [{ "action": "tool.use", "resource": "shell:sudo *", "effect": "deny" }],
  "plugins": ["@tarquinen/opencode-dcp@3.2.0"]
}`;

const CTX7 = "/usr/local/bin/context7-mcp";

const host = JSON.parse(
  HOST_CONFIG.split("\n").filter((l) => !l.trim().startsWith("//")).join("\n"),
);

test("drops the browse server and keeps context7", () => {
  const out = JSON.parse(buildOverlay(HOST_CONFIG, { context7Command: CTX7 }));
  assert.deepEqual(Object.keys(out.mcp.servers), ["context7"]);
});

test("rewrites the context7 command to the given absolute path", () => {
  const out = JSON.parse(buildOverlay(HOST_CONFIG, { context7Command: CTX7 }));
  assert.deepEqual(out.mcp.servers.context7.command, [CTX7]);
  assert.equal(out.mcp.servers.context7.type, "local");
});

test("preserves providers, plugins, permissions and policies unchanged", () => {
  const out = JSON.parse(buildOverlay(HOST_CONFIG, { context7Command: CTX7 }));
  assert.deepEqual(out.providers, host.providers);
  assert.deepEqual(out.plugins, host.plugins);
  assert.deepEqual(out.permissions, host.permissions);
  assert.deepEqual(out.policies, host.policies);
});

test("throws on malformed JSONC with the parse error", () => {
  assert.throws(
    () => buildOverlay('{ "providers": { "broken": } }', { context7Command: CTX7 }),
    /invalid config: /,
  );
});

test("keeps a valid file when the host has no mcp section", () => {
  const out = JSON.parse(buildOverlay('{ "plugins": [] }', { context7Command: CTX7 }));
  assert.deepEqual(out.plugins, []);
  assert.equal(out.mcp, undefined);
});
