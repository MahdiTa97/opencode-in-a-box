#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * Build the container-only config from the host's JSONC config.
 * Drops the host-attached `browse` MCP server and rewrites `context7` to the
 * command that exists inside the image.
 */
export function buildOverlay(sourceText, { context7Command }) {
  const stripped = sourceText
    .split("\n")
    .filter((line) => !line.trim().startsWith("//"))
    .join("\n");

  let config;
  try {
    config = JSON.parse(stripped);
  } catch (error) {
    throw new Error(`invalid config: ${error.message}`);
  }

  const servers = config.mcp && config.mcp.servers;
  if (servers) {
    delete servers.browse;
    if (servers.context7) {
      servers.context7.command = [context7Command];
    }
  }

  return JSON.stringify(config, null, 2) + "\n";
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [source, dest] = process.argv.slice(2);
  if (!source || !dest) {
    console.error("usage: overlay.mjs <source> <dest>");
    process.exit(2);
  }
  const context7Command = process.env.CONTEXT7_COMMAND || "/usr/local/bin/context7-mcp";
  const out = buildOverlay(readFileSync(source, "utf8"), { context7Command });
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, out, { mode: 0o600 });
}
