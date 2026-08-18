---
name: c-music
description: Fetch a background-music track from the CFW music library to a local file, ready to pass as $audio_track to a reel/short recipe. Resolves a library cdnUrl (obtained from the list_music_tracks MCP tool) into a validated local .mp3 on disk. Enforces a host allowlist so only licensed library tracks are ever downloaded.
when_to_use: Trigger whenever a pipeline needs background music / an audio_track and you have a library track cdnUrl from list_music_tracks (e.g. https://media.cfw.social/music/...). Run this BEFORE muxing — recipes mux a LOCAL file, not a URL. Also trigger on c-music, music library fetch, background music download, audio_track url.
allowed-tools: Bash
kind: component
visibility: internal
requires: ffmpeg, curl
---


# c-music — CFW Music Library Fetcher

> **SELF-IMPROVEMENT RULE — READ FIRST:**
> 1. Before executing ANY step in this skill, read `LEARNINGS.md` in this same folder.
> 2. Apply every item under **Active Feedback** as if it were a non-negotiable rule.
> 3. Only then proceed with the skill's normal instructions.
> 4. After completing the task, summarize any new gotcha into 1–3 bullet points and append to `LEARNINGS.md` with today's date.

## What this does

The CFW music library lives in cfw-social (system of record). The Director picks a
track by calling the **`list_music_tracks`** MCP tool, which returns rows with a public
**`cdnUrl`** (e.g. `https://media.cfw.social/music/global/<name>.mp3`).

Pipeline recipes (`p-ai-character`, reel formats) mux audio with `c-ffmpeg`, which
expects a **local file path**, not a URL. This component bridges that gap: it downloads
the chosen library track to disk, validates it is real audio, and echoes the local path
plus the track id (so the recipe can record `musicTrackId` for CC-BY attribution).

## Caller Variables

| Variable | Required | Source | Description |
|----------|----------|--------|-------------|
| `$MUSIC_CDN_URL` | Yes | Caller (from `list_music_tracks`) | Public R2 URL of the chosen track |
| `$MUSIC_TRACK_ID` | No | Caller (from `list_music_tracks`) | `MusicTrack.id` — echoed back; pass to `attach_output_to_composition(musicTrackId)` so CC-BY attribution auto-appends on publish |
| `{production}` | Yes | Caller | Absolute path to the production folder |

## Security — host allowlist (NON-NEGOTIABLE)

Only download from the CFW library host. **Never** fetch arbitrary external audio — that
is the whole point of the library (licensing). If `$MUSIC_CDN_URL` is not on the allowed
host, FAIL FAST with `MUSIC_FAILED:` and do not download.

Allowed host: `media.cfw.social`

## Steps

```bash
set -euo pipefail

# --- 0. Inputs ---
URL="${MUSIC_CDN_URL:?MUSIC_FAILED: MUSIC_CDN_URL is required}"
TRACK_ID="${MUSIC_TRACK_ID:-}"
PROD="${production:?MUSIC_FAILED: production folder path is required}"

# --- 1. Host allowlist (licensing guarantee) ---
HOST="$(printf '%s' "$URL" | sed -E 's#^https?://([^/]+)/.*#\1#')"
if [ "$HOST" != "media.cfw.social" ]; then
  echo "MUSIC_FAILED: refusing non-library host '$HOST' — only media.cfw.social tracks are licensed for use"
  exit 1
fi

# --- 2. Download to the production audio folder ---
DEST_DIR="$PROD/audio/music"
mkdir -p "$DEST_DIR"
BASENAME="$(printf '%s' "$URL" | sed -E 's#.*/##; s/[^A-Za-z0-9._-]/_/g')"
[ -n "$BASENAME" ] || BASENAME="track.mp3"
AUDIO_PATH="$DEST_DIR/$BASENAME"

if ! curl -fsSL --max-time 60 -o "$AUDIO_PATH" "$URL"; then
  echo "MUSIC_FAILED: could not download track from $URL"
  exit 1
fi

# --- 3. Validate it is real audio (has an audio stream, duration > 0) ---
DUR="$(ffprobe -v error -select_streams a:0 -show_entries format=duration \
        -of default=nw=1:nk=1 "$AUDIO_PATH" 2>/dev/null || true)"
if [ -z "$DUR" ] || awk "BEGIN{exit !($DUR > 0)}"; then :; else
  echo "MUSIC_FAILED: downloaded file has no valid audio stream ($AUDIO_PATH)"
  exit 1
fi

# --- 4. Emit results for the calling recipe ---
echo "AUDIO_PATH=$AUDIO_PATH"            # → pass as \$audio_track to c-ffmpeg mux
echo "MUSIC_TRACK_ID=$TRACK_ID"          # → pass to attach_output_to_composition(musicTrackId)
echo "MUSIC_DURATION_SEC=$DUR"
```

## Output contract

- `AUDIO_PATH=<local path>` — feed this as `$audio_track` into the recipe's mux step.
- `MUSIC_TRACK_ID=<id>` — feed this into `attach_output_to_composition(musicTrackId)` so
  CC-BY attribution is auto-appended to the published caption. (Empty if the caller did
  not pass one — attribution simply won't be appended.)
- `MUSIC_DURATION_SEC=<seconds>` — usable for trimming/pacing the visual to the track.

## Notes

- Loudness normalization is **not** done here — leave it to `c-ffmpeg`'s mux/loudnorm
  step (`-14 LUFS` master). This component only fetches + validates.
- Idempotent: re-running with the same URL re-downloads to the same path (overwrite).
