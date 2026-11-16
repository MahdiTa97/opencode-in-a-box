import test from "node:test";
import assert from "node:assert/strict";
import { buildOverlay, buildConfig } from "../overlay.mjs";

const JSONC = `{
  // host-only comment
  "providers": { "gateway": { "settings": { "apiKey": "{file:~/.secrets/gateway.key}" } } },
  "permissions": [{ "action": "edit", "resource": "*.env", "effect": "deny" }],
  "policies": [{ "action": "tool.use", "resource": "shell:sudo *", "effect": "deny" }],
  "plugins": ["@tarquinen/opencode-dcp@3.2.0"]
}`;

const MCP_JSON = `{
  "mcp": {
    "servers": {
      "context7": { "type": "local", "command": ["/home/you/.config/opencode/context7-mcp.sh"] },
      "browse": { "type": "local", "command": ["/usr/local/bin/browse", "mcp"] }
    }
  }
}`;

const CTX7 = "/usr/local/bin/context7-mcp";

test("merges mcp servers from the second config file", () => {
  const out = JSON.parse(buildOverlay([JSONC, MCP_JSON], { context7Command: CTX7 }));
  assert.deepEqual(Object.keys(out.mcp.servers), ["context7"]);
});

test("drops browse and keeps context7", () => {
  const out = JSON.parse(buildOverlay([JSONC, MCP_JSON], { context7Command: CTX7 }));
  assert.deepEqual(out.mcp.servers.context7.command, [CTX7]);
  assert.equal(out.mcp.servers.context7.type, "local");
});

test("preserves providers, plugins, permissions and policies", () => {
  const out = JSON.parse(
    buildOverlay([JSONC, MCP_JSON], { context7Command: CTX7, fileExists: () => true }),
  );
  assert.equal(out.providers.gateway.settings.apiKey, "{file:~/.secrets/gateway.key}");
  assert.deepEqual(out.plugins, ["@tarquinen/opencode-dcp@3.2.0"]);
  assert.equal(out.permissions.length, 1);
  assert.equal(out.policies.length, 1);
});

test("later files win on a conflicting key", () => {
  const out = JSON.parse(
    buildOverlay(['{ "plugins": ["a"] }', '{ "plugins": ["b"] }'], { context7Command: CTX7 }),
  );
  assert.deepEqual(out.plugins, ["b"]);
});

test("accepts inline comments and trailing commas", () => {
  const out = JSON.parse(
    buildOverlay(['{ "plugins": ["a"], /* block */ "permissions": [], }'], { context7Command: CTX7 }),
  );
  assert.deepEqual(out.plugins, ["a"]);
});

test("throws on malformed JSONC with the parse error", () => {
  assert.throws(
    () => buildOverlay(['{ "providers": { "broken": } }'], { context7Command: CTX7 }),
    /invalid config: /,
  );
});

test("keeps a valid file when no mcp section exists", () => {
  const out = JSON.parse(buildOverlay(['{ "plugins": [] }'], { context7Command: CTX7 }));
  assert.deepEqual(out.plugins, []);
  assert.equal(out.mcp, undefined);
});

const TWO_PROVIDERS = `{
  "providers": {
    "gateway": { "settings": { "apiKey": "{file:/home/dev/.secrets/gateway.key}" } },
    "plain": { "settings": { "apiKey": "literal-key" } }
  }
}`;

test("drops a provider whose key file is absent from the container", () => {
  const { config, dropped } = buildConfig([TWO_PROVIDERS], {
    context7Command: CTX7,
    fileExists: () => false,
  });
  assert.deepEqual(dropped, ["gateway"]);
  assert.deepEqual(Object.keys(config.providers), ["plain"]);
});

test("keeps a provider whose key file is mounted", () => {
  const { config, dropped } = buildConfig([TWO_PROVIDERS], {
    context7Command: CTX7,
    fileExists: () => true,
  });
  assert.deepEqual(dropped, []);
  assert.deepEqual(Object.keys(config.providers), ["gateway", "plain"]);
});

test("never drops a provider that carries no key reference", () => {
  const { config, dropped } = buildConfig(
    ['{ "providers": { "console": { "settings": { "baseURL": "https://example.test" } } } }'],
    { context7Command: CTX7, fileExists: () => false },
  );
  assert.deepEqual(dropped, []);
  assert.deepEqual(Object.keys(config.providers), ["console"]);
});

test("passes the Context7 API key to the MCP server when one is configured", () => {
  const { config } = buildConfig([JSONC, MCP_JSON], {
    context7Command: CTX7,
    context7ApiKey: "ctx7-test-key",
    fileExists: () => true,
  });
  assert.equal(config.mcp.servers.context7.environment.CONTEXT7_API_KEY, "ctx7-test-key");
  assert.deepEqual(config.mcp.servers.context7.command, [CTX7]);
});

test("leaves the MCP environment untouched when no Context7 key is configured", () => {
  const { config } = buildConfig([JSONC, MCP_JSON], {
    context7Command: CTX7,
    fileExists: () => true,
  });
  assert.equal(config.mcp.servers.context7.environment, undefined);
});

test("pins new worktrees inside the mounted project tree", () => {
  const { config } = buildConfig([JSONC], { context7Command: CTX7 });
  assert.deepEqual(config.worktree, { directory: "/work/.worktrees" });
});

test("keeps a worktree directory the host config already sets", () => {
  const { config } = buildConfig(
    [JSONC, '{ "worktree": { "directory": "/work/custom-trees" } }'],
    { context7Command: CTX7 },
  );
  assert.deepEqual(config.worktree, { directory: "/work/custom-trees" });
});

test("fills in the directory when the host config sets worktree without one", () => {
  const { config } = buildConfig([JSONC, '{ "worktree": {} }'], { context7Command: CTX7 });
  assert.deepEqual(config.worktree, { directory: "/work/.worktrees" });
});

test("warns when the worktree directory sits outside the mounted tree", () => {
  const warnings = [];
  buildConfig([JSONC, '{ "worktree": { "directory": "/srv/trees" } }'], {
    context7Command: CTX7,
    warn: (message) => warnings.push(message),
  });
  assert.equal(warnings.length, 1);
  assert.match(warnings[0], /\/srv\/trees/);
});
