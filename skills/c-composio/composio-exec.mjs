#!/usr/bin/env node
/**
 * composio-exec.mjs — Composio SDK executor for the c-composio recipe.
 *
 * Reads credentials from env (JIT-injected by the Hermes box vault layer):
 *   COMPOSIO_API_KEY    — Composio platform/brand API key
 *   COMPOSIO_ENTITY_ID  — per-brand entity id → passed as `userId` to the SDK
 *
 * Usage:
 *   node composio-exec.mjs \
 *     --provider google_drive \
 *     --action   list_files \
 *     --params   '{}' \
 *     [--slug    GOOGLEDRIVE_LIST_FILES] \
 *     [--out-dir /tmp]
 *
 * Exits 0 + prints JSON on success.
 * Exits 1 + prints { ok:false, error } on failure (never logs the API key).
 *
 * Box requirement: npm i -g @composio/core@0.10.0
 * SDK: @composio/core v3 — uses `userId` (not legacy `entityId`).
 *
 * @composio/core version: 0.10.0 (pinned; update deliberately)
 */

import { parseArgs } from "node:util";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";

// ── Slug map: (provider, action) → Composio tool slug ──────────────────────
// Extend here when adding new providers — the recipe contract stays unchanged.
const SLUG_MAP = {
  google_drive: {
    list_files:    "GOOGLEDRIVE_LIST_FILES",
    download_file: "GOOGLEDRIVE_DOWNLOAD_FILE",
  },
};

// ── Fail helper (never log the API key) ────────────────────────────────────
function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: message }) + "\n");
  process.exit(1);
}

// ── Parse CLI args ──────────────────────────────────────────────────────────
let args;
try {
  const parsed = parseArgs({
    args: process.argv.slice(2),
    options: {
      provider: { type: "string" },
      action:   { type: "string" },
      params:   { type: "string" },
      slug:     { type: "string" },
      "out-dir":{ type: "string" },
    },
    strict: true,
  });
  args = parsed.values;
} catch (err) {
  fail(`arg parse error: ${err.message}`);
}

const { provider, action, params: paramsRaw, slug: slugOverride, "out-dir": outDir = "/tmp" } = args;

if (!provider) fail("--provider is required (e.g. google_drive)");
if (!action)   fail("--action is required (e.g. list_files, download_file)");
if (!paramsRaw) fail("--params is required (JSON object, use '{}' for no params)");

// ── Parse params JSON ───────────────────────────────────────────────────────
let params;
try {
  params = JSON.parse(paramsRaw);
  if (typeof params !== "object" || params === null || Array.isArray(params)) {
    fail("--params must be a JSON object (not an array or primitive)");
  }
} catch {
  fail(`--params is not valid JSON: ${paramsRaw.slice(0, 120)}`);
}

// ── Validate provider/action or require --slug ──────────────────────────────
let toolSlug = slugOverride;
if (!toolSlug) {
  const providerMap = SLUG_MAP[provider];
  if (!providerMap) {
    const known = Object.keys(SLUG_MAP).join(", ");
    fail(`Unknown provider '${provider}'. Known: ${known}. Use --slug to pass a raw Composio tool slug.`);
  }
  toolSlug = providerMap[action];
  if (!toolSlug) {
    const knownActions = Object.keys(providerMap).join(", ");
    fail(`Unknown action '${action}' for provider '${provider}'. Known: ${knownActions}. Use --slug to pass a raw Composio tool slug.`);
  }
}

// ── Read vault-injected credentials ────────────────────────────────────────
const apiKey   = process.env["COMPOSIO_API_KEY"];
const entityId = process.env["COMPOSIO_ENTITY_ID"];

if (!apiKey)   fail("COMPOSIO_API_KEY is not set in env. Has Composio been connected for this brand? Store via set_brand_secret composio <apiKey>.");
if (!entityId) fail("COMPOSIO_ENTITY_ID is not set in env. Store via set_brand_secret composio-entity-id <entityId>.");

// ── Load @composio/core via createRequire (box-global install) ──────────────
// NODE_PATH is exported by the SKILL.md bash preamble so this resolves
// even when the subprocess CWD has no node_modules.
let ComposioClass;
try {
  // Try ESM-style dynamic import first (works if the package exports ESM)
  const mod = await import("@composio/core").catch(() => null);
  if (mod && (mod.Composio || mod.default?.Composio)) {
    ComposioClass = mod.Composio ?? mod.default.Composio;
  } else {
    // Fall back to CJS via createRequire against the global node_modules
    const globalRoot = process.env["NODE_PATH"]?.split(path.delimiter)[0];
    if (!globalRoot) fail("@composio/core not found: neither ESM import nor NODE_PATH resolve succeeded. Run: npm i -g @composio/core@0.10.0");
    const require = createRequire(path.join(globalRoot, "x"));
    const cjsMod = require("@composio/core");
    ComposioClass = cjsMod.Composio ?? cjsMod.default?.Composio;
  }
} catch (err) {
  fail(`Failed to load @composio/core: ${err.message}. Run: npm i -g @composio/core@0.10.0`);
}

if (!ComposioClass) {
  fail("@composio/core loaded but Composio class not found. Check the package version (expected 0.10.0).");
}

// ── Execute the Composio tool ───────────────────────────────────────────────
let result;
try {
  const composio = new ComposioClass({ apiKey });
  result = await composio.tools.execute(toolSlug, {
    userId: entityId,   // v3 renames entityId → userId (same value)
    arguments: params,
  });
} catch (err) {
  // Never include the apiKey in the error message
  const msg = err?.message ?? String(err);
  fail(`Composio ${toolSlug} failed: ${msg}`);
}

// ── Normalize output per action ────────────────────────────────────────────
// The exact response shape is:
//   - result.data (the tool's output object)
//   - result.error (if the tool itself reported an error)
// We normalize defensively: surface the most useful fields.

if (result?.error || result?.data?.error) {
  const errMsg = result?.error ?? result?.data?.error;
  fail(`Composio returned an error for ${toolSlug}: ${JSON.stringify(errMsg)}`);
}

const data = result?.data ?? result ?? {};

// ── download_file: write bytes/URL to disk ─────────────────────────────────
if (action === "download_file") {
  // Composio download_file may return:
  //   - data.file_content (base64)  — binary blob
  //   - data.download_url           — temporary signed URL
  //   - data.file (object with content or url)
  // We handle all three; if none present, surface the raw data for debugging.

  const fileName = sanitizeFilename(
    data?.file_name ?? data?.name ?? data?.fileName ?? params?.fileId ?? "composio-download"
  );
  const mimeType = data?.mime_type ?? data?.mimeType ?? "application/octet-stream";
  const destPath = path.join(outDir, fileName);

  if (data?.file_content) {
    // Base64-encoded content
    const buf = Buffer.from(data.file_content, "base64");
    fs.writeFileSync(destPath, buf);
    process.stdout.write(JSON.stringify({ ok: true, localPath: destPath, fileName, mimeType }) + "\n");
  } else if (data?.download_url ?? data?.file?.download_url) {
    // Temporary signed URL — download via Node fetch (available in Node ≥ 18)
    const url = data?.download_url ?? data?.file?.download_url;
    const response = await fetch(url);
    if (!response.ok) {
      fail(`download_file: signed URL fetch failed: ${response.status} ${response.statusText}`);
    }
    const arrayBuf = await response.arrayBuffer();
    fs.writeFileSync(destPath, Buffer.from(arrayBuf));
    process.stdout.write(JSON.stringify({ ok: true, localPath: destPath, fileName, mimeType }) + "\n");
  } else {
    // Surface raw data so the caller can inspect and we can improve the normalizer
    fail(
      `download_file: unexpected response shape from Composio (cannot locate file content). ` +
      `Raw keys: ${Object.keys(data).join(", ")}. ` +
      `Open an issue to extend composio-exec.mjs with this shape.`
    );
  }
} else if (action === "list_files") {
  // Composio list_files may return:
  //   - data.files  (array)
  //   - data.items  (array)
  //   - data (array directly)
  const rawFiles = data?.files ?? data?.items ?? (Array.isArray(data) ? data : null);
  if (!rawFiles) {
    // Empty drive is valid — return empty array, not an error.
    // If data is entirely unexpected, surface for debugging.
    if (Object.keys(data).length === 0) {
      process.stdout.write(JSON.stringify({ ok: true, files: [] }) + "\n");
    } else {
      fail(
        `list_files: unexpected response shape from Composio. ` +
        `Raw keys: ${Object.keys(data).join(", ")}. ` +
        `Open an issue to extend composio-exec.mjs with this shape.`
      );
    }
    process.exit(0); // only reached in the empty-array case above
  }

  const files = rawFiles.map((f) => ({
    id:           f?.id ?? f?.fileId ?? f?.file_id ?? null,
    name:         f?.name ?? f?.title ?? f?.fileName ?? null,
    mimeType:     f?.mimeType ?? f?.mime_type ?? f?.type ?? null,
    size:         f?.size ?? f?.fileSize ?? null,
    modifiedTime: f?.modifiedTime ?? f?.modified_time ?? f?.updatedAt ?? null,
  }));

  process.stdout.write(JSON.stringify({ ok: true, files }) + "\n");
} else {
  // Generic passthrough for any action accessed via --slug override
  process.stdout.write(JSON.stringify({ ok: true, data }) + "\n");
}

// ── Helpers ────────────────────────────────────────────────────────────────
/**
 * Sanitize a filename from Composio: basename only (no path traversal),
 * replace shell-dangerous chars with underscores.
 */
function sanitizeFilename(name) {
  if (!name || typeof name !== "string") return "composio-download";
  // Strip any leading path components (no traversal)
  const base = path.basename(name);
  // Replace chars that would be dangerous in a shell path or filesystem
  return base.replace(/[^\w.\-]/g, "_") || "composio-download";
}
