---
name: c-cloud-media
description: Media upload (via the CFW Social API — R2 is never exposed), CDN URL retrieval, and CFW Social API operations. Use for uploading b-roll clips / rendered videos / images and getting back a CDN URL, registering assets in CFW, fetching content/variants, updating variant scripts with b-roll tags, and finding stuck CFW workflow executions.
when_to_use: Trigger on R2 upload, CDN upload, Cloudflare R2, cloud upload, CFW Social, register asset, fetch content, variant update, b-roll embed, CFW variant, CFW content, stuck execution, workflow execution, c-broll upload CDN, cloud media.
allowed-tools: Bash
kind: component
visibility: internal
dependsOn: [c-broll]
requires: python3
---


# Cloud Media — Upload via CFW Social API & CFW Social API ops


> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, ask the user: "How did this go? Any corrections or improvements for next time?"
> 5. Summarize the feedback into 1–3 bullet points and append to `LEARNINGS.md` with today's date.
> 6. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section so it applies on every future run.

> **ARCHITECTURE (2026-06-05): R2 is NEVER exposed to this skill.** All uploads go
> THROUGH cfw-social (`POST /api/v1/media/upload`), which performs the R2 PUT
> server-side and returns a CDN URL. This skill holds **no R2/AWS credentials** — only
> the brand key (`$CFW_API_KEY`) and the API base (`$CFW_API_BASE`). The old
> `rclone` / `_scripts/upload-to-recordings.sh` direct-to-R2 paths and the `R2_*` /
> `AWS_*` env vars were removed. **Never fall back to direct R2** — if the API call
> fails, report the exact error and stop.

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `$LOCAL_FILE` | Yes | Caller | Absolute path to the `image/*` or `video/*` file to upload |
| `$CFW_API_KEY` | Yes | brand vault / env (`x-api-key`) | CFW Social **brand key** — authenticates the upload + V2 API calls |
| `$CFW_API_BASE` | Yes | env | CFW Social V2 base URL (e.g. `https://app.cfw.social`) |
| `$BRAND_ACCOUNT_ID` | Legacy | Caller / brand config | Only for the legacy V1 register/content sections below — NOT needed for upload (the API derives the R2 key from the authed brand) |
| `$FOLDER_ID` | Legacy | Caller / brand config | As above — legacy V1 only |

## Upload (via CFW Social API — R2 never exposed)

`POST /api/v1/media/upload` — multipart `files` field, ≤100 MB per file, mime must be
`image/*` or `video/*`. Response: `{ assets: [{ cdnUrl, mimeType }], kind }`. cfw-social
does the R2 write; this skill only sends bytes + reads back the CDN URL.

```bash
upload_media () {   # $1 = absolute path to an image/* or video/* file → prints the CDN URL
  local LOCAL_FILE="$1"
  [ -s "$LOCAL_FILE" ] || { echo "ERROR: file not found or empty: $LOCAL_FILE" >&2; return 1; }
  : "${CFW_API_BASE:?set CFW_API_BASE}" "${CFW_API_KEY:?set CFW_API_KEY (brand key)}"

  # The endpoint REQUIRES the part's content-type to start with image/ or video/.
  # curl sends application/octet-stream for -F @file by default, so derive + pin it.
  local EXT MIME
  EXT=$(printf '%s' "${LOCAL_FILE##*.}" | tr '[:upper:]' '[:lower:]')
  case "$EXT" in
    mp4) MIME=video/mp4 ;;  mov) MIME=video/quicktime ;;  webm) MIME=video/webm ;;  m4v) MIME=video/x-m4v ;;
    png) MIME=image/png ;;  jpg|jpeg) MIME=image/jpeg ;;  gif) MIME=image/gif ;;  webp) MIME=image/webp ;;
    *) echo "ERROR: unsupported extension .$EXT — media/upload accepts image/* or video/* only" >&2; return 1 ;;
  esac

  local RESP
  RESP=$(curl -sf -X POST "$CFW_API_BASE/api/v1/media/upload" \
           -H "x-api-key: $CFW_API_KEY" \
           -F "files=@$LOCAL_FILE;type=$MIME") \
    || { echo "ERROR: media/upload failed for $LOCAL_FILE (auth? >100MB? mime?)" >&2; return 1; }

  printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["assets"][0]["cdnUrl"])'
}

# Single file
CDN_URL=$(upload_media "$LOCAL_FILE") || exit 1
echo "$CDN_URL"
```

> If `$CFW_API_KEY` / `$CFW_API_BASE` is unset, or the upload returns non-2xx, the
> function FAILS LOUD and returns non-zero — do not retry against R2 directly, and do
> not invent a CDN URL. Report the exact error to the caller.

## Register Asset in CFW Social  ⚠️ LEGACY V1 — pending V2 migration

> The endpoints below target the V1 API (`api.cfw.social`, `Authorization: Bearer`).
> They are NOT part of the V2 path and may not exist on the V2 stack. The V2 upload
> above already returns a CDN URL; asset/output registration in V2 goes through the
> MCP back-channel (e.g. `attach_output`), not this V1 route. Left here for reference
> until a V2 replacement is wired. Do not assume these work on the V2 runtime.

```bash
curl -s -X POST "https://api.cfw.social/api/brand-assets" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CFW_API_KEY" \
  -d "{
    \"cdn_url\": \"$CDN_URL\",
    \"folder_id\": \"$FOLDER_ID\",
    \"file_name\": \"$FILE_NAME\",
    \"brand_account_id\": \"$BRAND_ACCOUNT_ID\"
  }"
```

Returns `asset_id`. Update c-broll library with `Cloud: $CDN_URL` and `Status: Uploaded`.

## CFW Social Content API  ⚠️ LEGACY V1 — pending V2 migration

### Fetch Content (get script)

```bash
# By content ID
curl -s "https://api.cfw.social/api/content/$CONTENT_ID" \
  -H "Authorization: Bearer $CFW_API_KEY"
# Returns: sourceText, title, platform, status

# By variant ID
curl -s "https://api.cfw.social/api/variants/$VARIANT_ID" \
  -H "Authorization: Bearer $CFW_API_KEY"
# Returns: script, status, platform, contentId
```

### Update Variant Script (embed b-roll tags)

```bash
curl -s -X PATCH "https://api.cfw.social/api/variants/$VARIANT_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CFW_API_KEY" \
  -d "{\"script\": \"$UPDATED_SCRIPT_WITH_BROLL_TAGS\"}"
```

B-roll tag format embedded in script: `[B-ROLL: wbst01 | 0:15-0:21]`

### Submit Video ID (link final render to CFW)

```bash
curl -s -X POST "https://api.cfw.social/api/variants/$VARIANT_ID/video" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CFW_API_KEY" \
  -d "{\"video_url\": \"$CDN_URL\", \"duration\": $DURATION}"
```

## Floe API — Workflow Execution  ⚠️ LEGACY V1

Base URL: `https://floe-production.up.railway.app`
Auth: `X-API-Key: $FLOE_API_KEY`

All requests require a unique `execution_id` — use `$(date +%s)` suffix to ensure uniqueness.

### Find Stuck Executions

```bash
curl -s "https://floe-production.up.railway.app/api/v1/executions?status=stuck" \
  -H "X-API-Key: $FLOE_API_KEY" | python3 -m json.tool
```

### Retry Stuck Execution

```bash
curl -s -X POST "https://floe-production.up.railway.app/api/v1/executions/$EXECUTION_ID/retry" \
  -H "X-API-Key: $FLOE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"execution_id\": \"retry-$(date +%s)\"}"
```

## Bulk Upload Workflow (Pending B-Roll)

1. Read c-broll library — find all rows with `Status: Pending`
2. For each: upload via the API (`upload_media`), get the CDN URL
3. (Legacy/optional) register in CFW Social — get asset_id
4. Update library row: `Status: Uploaded`, `Cloud: $CDN_URL`
5. Log completion summary

```bash
# (define upload_media from the Upload section above first)

# Find pending clips in library
grep "Pending" {brand_path}/creatives/brolls/recordings-broll-library.md

# Upload each via the CFW Social API
for FILE in {brand_path}/creatives/brolls/recordings/wbst*.mp4; do
  CDN_URL=$(upload_media "$FILE") || { echo "skip $FILE (upload failed)"; continue; }
  echo "$FILE → $CDN_URL"
done
```

## Output Notes

- After upload: update library `Cloud` column with the returned CDN URL, `Status` → `Uploaded`
- The CDN URL is whatever `POST /api/v1/media/upload` returns in `assets[].cdnUrl` — do NOT
  construct or hardcode it (cfw-social owns the R2 key + public domain).
- This skill never holds R2/AWS credentials. If you find yourself reaching for `rclone`,
  `R2_*`, or `AWS_*`, stop — that path was removed on purpose.

## Self-Improvement Feedback Loop

After completing this skill's task:
1. Ask the user: "How did this go? Any corrections or improvements for next time?"
2. Summarize feedback into 1–3 concise bullet points.
3. Append to `LEARNINGS.md` in this folder with the date.
4. If feedback is critical (affects correctness or quality), add it to the **Active Feedback** section at the top of `LEARNINGS.md`.
5. Mark critical feedback with `[ACTIVE]` prefix so it is visually distinct.
