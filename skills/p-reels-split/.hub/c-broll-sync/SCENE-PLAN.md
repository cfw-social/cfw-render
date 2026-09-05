# `scene_plan` — the card-copy directive contract (v1)

> **Why this exists.** `plan.js` decides *where* b-roll goes, but nothing in the chain writes
> the words on a motion-graphics card. In a headless render (cfw-render fleet, kimi-k3 Director)
> that meant blank cards shipped (CFW-128 gap #1). The `scene_plan` directive makes card copy
> the **Director's explicit job**, validated *before* any card is rendered. `plan.js` refuses to
> emit a graphics beat without copy (exit 1) unless `--allow-empty-copy` is passed.

The Director produces `work/scene_plan.json` (from the order's `scene_plan` ingredient if one
was supplied, otherwise **authored from the script after transcription**) and passes it to the
planner: `plan.js --scene-plan work/scene_plan.json`. Validate it any time with
`node scripts/validate-scene-plan.js work/scene_plan.json --bed-dur <s> [--transcript words.json]`.

## Shape

```json
{
  "version": 1,
  "bed_duration": 47.07,
  "scenes": [
    { "id": "hook",  "kind": "graphic", "start": 0.0,  "end": 4.72,
      "type": "hook", "eyebrow": "NOBODY TALKS ABOUT THIS", "ghost": "?",
      "headline": "THE CLAUDE FEATURE THAT <span class=\"accent\">CHANGED</span> HOW I WORK" },
    { "id": "mcp",   "kind": "graphic", "start_phrase": "It's called", "end_phrase": "It connects",
      "type": "terminal", "ghost": "MCP", "eyebrow": "MODEL CONTEXT PROTOCOL",
      "headline": "IT'S CALLED <span class=\"accent\">MCP</span>",
      "lines": ["$ claude mcp add filesystem ~/notes", "✓ connected  filesystem"] },
    { "id": "b1",    "kind": "broll",   "start": 9.88, "end": 14.88,
      "asset": "kb01-octopus-searching.mp4", "in": 0, "cover": true },
    { "id": "cta",   "kind": "graphic", "start": 39.46, "end": 47.07,
      "type": "cta", "ghost": "DM", "eyebrow": "WANT THE EXACT CONFIG?",
      "headline": "COMMENT <span class=\"accent\">MCP</span>", "sub": "I'll DM you the config" }
  ]
}
```

| Field | Scope | Required | Notes |
|---|---|---|---|
| `version` | top | yes | literal `1` |
| `bed_duration` | top | no | seconds; `plan.js` fills it from the transcript when absent |
| `scenes[]` | top | yes | **sorted, gapless, non-overlapping**, covering `0 → bed_duration` (±0.25 s) |
| `id` | scene | no | slug; becomes the beat `slug` (`beat<N>-<id>`) → `gfx/<slug>/<slug>.mp4` |
| `kind` | scene | yes | `graphic` · `broll` · `avatar` |
| `start` / `end` | scene | yes* | seconds. *Or `start_phrase` / `end_phrase` — a verbatim word sequence from the transcript; `end_phrase` is the **first word of the next scene**. A scene without `end` ends where the next starts (last one at `bed_duration`). |
| `headline` | graphic | **yes** | plain text + only `<span class="accent">…</span>` and `<br>`; ≤ 90 chars of text. **Empty = hard error.** |
| `eyebrow` | graphic | no | ≤ 40 chars, UPPERCASE mono label |
| `ghost` | graphic | no | ≤ 4 chars — a number / letter / short word-mark (never "CTA"/"TITLE") |
| `sub` | graphic | no | supporting line |
| `type` | graphic | no | `hook` · `standard` · `terminal` · `chips` · `flow` · `checklist` · `stat` · `cta` · `typing-ui` · `chart` (default `standard`) |
| any other key | graphic | no | passed through verbatim on `beat.scene` (`lines`, `chips`, `items`, `flow`, `stat`, `unit`, …) for the card generator |
| `asset` | broll | **yes** | clip filename / label from `BROLL_JSON`, or a readable local path |
| `in` | broll | no | trim start inside the clip (s); window length = scene length |
| `asset` | avatar | no | pass-through for pip/spotlight cores (`beat.kind = "avatar"`) |
| `cover` | any | no | `true` on exactly one scene → `cover_at` = that scene's start + min(half, 2 s). Use it on dark-palette brands to put the cover on a b-roll frame. |

## Rules the validator enforces (exit 1)

1. Every `graphic` scene has non-empty `headline` text (tags stripped). **Never blank cards.**
2. `headline` contains no markup other than the accent span / `<br>`; ≤ 90 chars.
3. Graphic scene length ∈ [1.0, 12.0] s (warns above 8 s — split long windows).
4. Scenes are sorted, no overlap (> 0.05 s), no gap (> 0.25 s), start at 0, end at `bed_duration` (±0.25 s).
5. `broll` scenes carry an `asset`; `in ≥ 0`.
6. Phrase anchors resolve against the transcript.

## How `plan.js` applies it

- **Plan has `broll` scenes** → they *are* the b-roll placements (coverage/order strategies are
  bypassed). `asset` resolves by exact clip path, basename, or `label`; a bare readable path not in
  `BROLL_JSON` is appended as a new clip.
- **Plan has no `broll` scenes** → the planner places b-roll per `--coverage`/`--order` as before,
  then every remaining graphics window is filled with the `graphic` scenes that overlap it, clipped
  to the window. Fragments shorter than `--min-card-secs` (1.0 s) merge into their neighbour. A
  window no scene covers is an error.
- Each graphics beat gets `scene: { eyebrow, ghost, title_html: headline, sub, type, scene_id,
  source: "scene_plan", brand, …passthrough }` plus a `slug`.
- `avatar` scenes emit `kind: "avatar"` beats (`avatar.asset`), left to the calling core.

## Ordering it through cfw-render

`order.json` `directives[]` entries are ≤ 500 chars, so a full plan does not fit there. Either:
- supply it as an **ingredient**: `{ "kind": "doc", "url": "https://media.cfw.social/…/scene_plan.json", "note": "scene_plan" }` and add the directive `scene_plan=ingredient` — the Director copies it to `work/scene_plan.json`; or
- add nothing and let the Director **author** it from `intent`/`copy` after transcription (the
  cfw-render Director prompt has this as an explicit step, and validates before Step 5).

Tests: `node --test c-broll-sync/test/scene-plan.test.js` (19 cases).
