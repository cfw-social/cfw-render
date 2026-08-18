---
name: c-composio
description: Call a connected Composio app (e.g. Google Drive) on behalf of the current brand. Executes one action (list_files, download_file, etc.) using the brand's vaulted Composio credentials, and returns structured JSON. Use this whenever a cook needs to read or download from a connected integration — NOT for uploading to CFW (use cfw-upload for that).
when_to_use: Trigger whenever the Director needs to interact with a brand's connected Composio integration — reading Google Drive files, listing folder contents, downloading a file for use in a reel or carousel. Common triggers: "list my drive files", "download the file from Google Drive", "what's in my Drive folder", run_skill c-composio, composio, gdrive, google_drive action. Always run c-composio BEFORE any recipe that needs a local file from a connected cloud storage.
allowed-tools: Bash
kind: component
visibility: internal
requires: node
---


# c-composio — Composio Integration Bridge

> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, summarize any new gotcha into 1–3 bullet points and append to `LEARNINGS.md` with today's date.

## What this does

This component bridges the brand's connected Composio apps (Google Drive first) to
the cook runtime. Composio credentials (`COMPOSIO_API_KEY`, `COMPOSIO_ENTITY_ID`) are
**JIT-injected from the cfw-social brand vault** by the box — they arrive in the skill
subprocess env the same way `CFW_API_KEY` does. The recipe reads them from env and
passes them to `@composio/core` — no manual vault calls needed.

The `composio-exec.mjs` Node shim performs the actual SDK call and prints JSON to
stdout. The bash body here wires it up and captures the result.

## Caller Variables

| Variable | Required | Source | Description |
|---|---|---|---|
| `$COMPOSIO_PROVIDER` | Yes | Caller | Provider slug: `google_drive` |
| `$COMPOSIO_ACTION` | Yes | Caller | Action: `list_files`, `download_file` |
| `$COMPOSIO_PARAMS` | Yes | Caller | JSON object passed as Composio `arguments` (e.g. `{}` for list, `{"fileId":"…"}` for download) |
| `$COMPOSIO_SLUG` | No | Caller | Explicit Composio tool slug override (bypasses the provider/action map — use for actions not yet in the map) |
| `$COMPOSIO_OUT_DIR` | No | Caller | Local dir for `download_file` output (default: `/tmp`) |
| `COMPOSIO_API_KEY` | Yes | **vault → JIT env** | Composio platform/brand API key (do NOT pass as arg — comes from env) |
| `COMPOSIO_ENTITY_ID` | Yes | **vault → JIT env** | Per-brand Composio entity ID, passed as `userId` to the SDK |

## Steps

```bash
set -euo pipefail

# ── 0. Guard: require vault-injected credentials ───────────────────────────
# These are JIT-injected from the brand vault; if absent, Composio is not
# connected for this brand — fail fast with a clear, actionable message.
: "${COMPOSIO_API_KEY:?COMPOSIO_FAILED: COMPOSIO_API_KEY not in env. Has the brand connected a Composio integration? Set via set_brand_secret composio <apiKey>.}"
: "${COMPOSIO_ENTITY_ID:?COMPOSIO_FAILED: COMPOSIO_ENTITY_ID not in env. Set via set_brand_secret composio-entity-id <entityId>.}"

# ── 1. Inputs ──────────────────────────────────────────────────────────────
PROVIDER="${COMPOSIO_PROVIDER:?COMPOSIO_FAILED: COMPOSIO_PROVIDER is required (e.g. google_drive)}"
ACTION="${COMPOSIO_ACTION:?COMPOSIO_FAILED: COMPOSIO_ACTION is required (e.g. list_files, download_file)}"
PARAMS="${COMPOSIO_PARAMS:?COMPOSIO_FAILED: COMPOSIO_PARAMS is required (JSON object, use {} for no params)}"
SLUG_OVERRIDE="${COMPOSIO_SLUG:-}"
OUT_DIR="${COMPOSIO_OUT_DIR:-/tmp}"

# ── 2. Resolve SKILL_DIR (the dir this SKILL.md lives in) ──────────────────
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 3. Ensure @composio/core is resolvable ─────────────────────────────────
# The SDK is installed box-global (npm i -g @composio/core@0.10.0).
# Export NODE_PATH so Node resolves the bare specifier from the global modules
# directory, regardless of the subprocess working directory.
GLOBAL_NODE_MODULES="$(npm root -g 2>/dev/null || true)"
if [ -n "$GLOBAL_NODE_MODULES" ]; then
  export NODE_PATH="$GLOBAL_NODE_MODULES${NODE_PATH:+:$NODE_PATH}"
fi

# ── 4. Build the argument list ─────────────────────────────────────────────
EXEC_ARGS=(
  --provider "$PROVIDER"
  --action   "$ACTION"
  --params   "$PARAMS"
  --out-dir  "$OUT_DIR"
)
if [ -n "$SLUG_OVERRIDE" ]; then
  EXEC_ARGS+=(--slug "$SLUG_OVERRIDE")
fi

# ── 5. Run the Node shim ───────────────────────────────────────────────────
# The shim reads COMPOSIO_API_KEY + COMPOSIO_ENTITY_ID from env (already present).
# It prints JSON to stdout: { ok, files } for list_files
#                            { ok, localPath, fileName, mimeType } for download_file
#                            { ok:false, error } + non-zero exit on failure
RESULT="$(node "$SKILL_DIR/composio-exec.mjs" "${EXEC_ARGS[@]}")"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "COMPOSIO_FAILED: $RESULT"
  exit 1
fi

# ── 6. Emit result ─────────────────────────────────────────────────────────
echo "$RESULT"
```

## Output contract

- **`list_files`** → `{ "ok": true, "files": [{ "id", "name", "mimeType", "size", "modifiedTime" }, …] }`
- **`download_file`** → `{ "ok": true, "localPath": "/tmp/<filename>", "fileName": "<name>", "mimeType": "<type>" }`
  Pass `localPath` as `$LOCAL_FILE` to `c-cloud-media` or `c-ffmpeg` for further processing.
- **Error** → `{ "ok": false, "error": "<message>" }` + non-zero exit. The error is printed
  with a `COMPOSIO_FAILED:` prefix so the caller and gateway logs surface it clearly.

## Security

- Credentials come from the brand vault JIT env ONLY — never from caller args.
  A caller cannot override `COMPOSIO_API_KEY` or `COMPOSIO_ENTITY_ID` via recipe variables.
- The shim never logs or includes the API key in error output.
- `download_file` writes ONLY to `$COMPOSIO_OUT_DIR` using the filename from Composio
  (basename-sanitized, no path traversal).
- This recipe operates on the CURRENT brand's credentials only — cross-tenant access
  is impossible (each gateway holds its own brand key → only its own vault secrets).

## Example usage

```bash
# List files in the brand's Google Drive root
COMPOSIO_PROVIDER=google_drive \
COMPOSIO_ACTION=list_files \
COMPOSIO_PARAMS='{}' \
run_skill c-composio

# List files in a specific folder
COMPOSIO_PROVIDER=google_drive \
COMPOSIO_ACTION=list_files \
COMPOSIO_PARAMS='{"folder_id": "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms"}' \
run_skill c-composio

# Download a specific file
COMPOSIO_PROVIDER=google_drive \
COMPOSIO_ACTION=download_file \
COMPOSIO_PARAMS='{"fileId": "1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms"}' \
COMPOSIO_OUT_DIR=/tmp \
run_skill c-composio
# → { "ok": true, "localPath": "/tmp/my-file.mp4", "fileName": "my-file.mp4", "mimeType": "video/mp4" }
# Pass localPath to cfw-upload or c-ffmpeg.
```

## Notes

- **box-global install required:** `npm i -g @composio/core@0.10.0` must be run on the
  box before this skill can execute. The provisioner runbook documents this step.
- **Action map:** v1 supports `google_drive` → `list_files` / `download_file`. For any
  other Composio tool, use `$COMPOSIO_SLUG` to pass the raw tool slug directly
  (e.g. `COMPOSIO_SLUG=GOOGLEDRIVE_CREATE_FOLDER`). New providers extend the map in
  `composio-exec.mjs`.
- **Vault keys:** The CONNECT task must store `composio` → `COMPOSIO_API_KEY` and
  `composio-entity-id` → `COMPOSIO_ENTITY_ID` via `set_brand_secret`. The exact slugs
  are the contract between the connect flow and this recipe.
