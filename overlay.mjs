#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname } from "node:path";
import { pathToFileURL } from "node:url";

/**
 * Strip comments and trailing commas from JSONC without touching string
 * contents, so files OpenCode accepts do not kill the container.
 */
function stripJsonc(text) {
  let out = "";
  let inString = false;
  let escaped = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const next = text[i + 1];

    if (inString) {
      out += c;
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }

    if (c === '"') {
      inString = true;
      out += c;
      continue;
    }

    if (c === "/" && next === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
      continue;
    }

    if (c === "/" && next === "*") {
      i += 2;
      while (i < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++;
      i++;
      continue;
    }

    out += c;
  }

  return out.replace(/,(\s*[}\]])/g, "$1");
}

function deepMerge(base, extra) {
  if (
    base === null || extra === null ||
    typeof base !== "object" || typeof extra !== "object" ||
    Array.isArray(base) || Array.isArray(extra)
  ) {
    return extra;
  }
  const out = { ...base };
  for (const [key, value] of Object.entries(extra)) {
    out[key] = key in out ? deepMerge(out[key], value) : value;
  }
  return out;
}

/**
 * Build the container-only config: merge the host's config files in order,
 * drop the host-attached `browse` MCP server and point `context7` at the
 * command that exists inside the image.
 */
export function buildOverlay(sources, { context7Command }) {
  const texts = Array.isArray(sources) ? sources : [sources];
  let config = {};

  for (const text of texts) {
    let parsed;
    try {
      parsed = JSON.parse(stripJsonc(text));
    } catch (error) {
      throw new Error(`invalid config: ${error.message}`);
    }
    config = deepMerge(config, parsed);
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

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error("usage: overlay.mjs <dest> <source...>");
    process.exit(2);
  }
  const dest = args[0];
  const sources = args.slice(1).filter((path) => existsSync(path));
  if (sources.length === 0) {
    console.error("no readable source config");
    process.exit(1);
  }
  const context7Command = process.env.CONTEXT7_COMMAND || "/usr/local/bin/context7-mcp";
  const out = buildOverlay(
    sources.map((path) => readFileSync(path, "utf8")),
    { context7Command },
  );
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, out, { mode: 0o600 });
}
