# Plan the edit

**You are the planner.** The engine running this step (Codex or Claude Code) reads the transcript
and the brand, thinks, and writes ONE curated `edit_plan.json` itself. There is no separate model
call, no API key and no fallback model. Every later step is a mechanical executor that fills
templates from this plan and never invents anything.

## You receive

- `prior/voice_track.mp4` — the sealed bed; probe it for `DUR`.
- `prior/transcripts.json` — use `.words` (`[{text,start,end}]`). Ignore `.broll_cues` here;
  b-roll placement is a later step.
- `brief.json` — brand (palette via the Visual Identity Gate), intent, `options.grade` if set.

## You must produce

- `saves/edit_plan.json` — STRICT JSON, one object, no prose:

```json
{ "duration": DUR, "energy": "high|medium|low", "grade": "warm-amber|clean-bright",
  "cover_at": <float seconds — a content beat past the hook, NOT t=0, NOT in the hook scene>,
  "brand": {"bg":"#hex6","accent":"#hex6","fg":"#hex6"},
  "takeovers": [ {"start":s,"end":s,"template":"tk-stat|tk-keyword|tk-list|tk-quote|tk-typing-ui",
                  "fill":{...per-template keys...}} ],
  "caption_groups": [ {"start":s,"end":s,"style":0|1|2,
        "words":[{"w":"TEXT","s":start,"e":end,"em":false}] } ],
  "sfx": [ {"t":s,"name":"whoosh-deep|whoosh-air|impact-sub|impact-punch|riser|click|pop|swipe","gain":0.0-0.8} ] }
```

Template fill keys — `tk-stat`: EYEBROW, STAT (short, e.g. `3X` or `70%`), LABEL. `tk-keyword`:
WORD (one word), SUPPORT (short line). `tk-list`: TITLE, ITEM1, ITEM2, ITEM3. `tk-quote`: QUOTE,
ATTR. TITLE and QUOTE may wrap ONE key word in `<span class="accent">WORD</span>`. `tk-typing-ui`:
LABEL (e.g. `claude.ai`), PROMPT (the typed text), TYPING_SPEED (0.5–1.5), BOTTOM_TAG.

## How

```bash
mkdir -p work saves
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 prior/voice_track.mp4)
python3 -c "import json; json.dump(json.load(open('prior/transcripts.json'))['words'], open('work/words.json','w'))"
```

Read `work/words.json` and `brief.json`. Resolve the brand hexes (brand brief → palette in
`brief.json` → named style → default `#0F172A` / `#F97316` / `#F1F5F9`; 6-digit, single `#`).
Then write `saves/edit_plan.json` with your file-writing tool, following these rules:

1. `caption_groups` cover the FULL duration, 2–4 words each, non-overlapping, breaking on sentence
   boundaries or pauses ≥ 150 ms. Words VERBATIM from the transcript.
2. LATIN SCRIPT ONLY: transliterate any Devanagari (or other non-Latin) word phonetically. Never
   translate.
3. At most ONE word per group gets `"em": true`. Some groups have none.
4. `style` cycles 0/1/2 — never the same style on adjacent groups.
5. `takeovers`: 2–4 windows, 3–6 s each, first no earlier than t=2, none in the final 2 s (and
   none overlapping the final `cta_duration` seconds, default 3, where the end card sits), ≥ 4 s of
   speaker between windows, never the same template twice in a row. Content restates what is SAID
   in that window. Use `tk-typing-ui` only when the content involves AI / prompts / terminal work.
6. `sfx`: `whoosh-deep` at every takeover start, `impact-sub` 0.4 s later, optional `riser` 1.5 s
   before the biggest takeover, `click`/`pop` on at most 3 emphasis words. Max 12 cues, gain ≤ 0.6.
7. `cover_at`: a mid-content frame (ideally mid-sentence at peak energy) — NEVER t=0 or the first
   3 s. Typically 20–60 % of the duration, and not inside a takeover window (the cover must show
   the speaker).
8. A visible change (takeover, emphasis pop or caption style shift) every 2–4 seconds.
9. `grade`: honour `brief.json.options.grade` when set; otherwise pick `warm-amber` for warm /
   personal content and `clean-bright` for product / tech content.

Then run the mechanical guard — fix the plan and rerun until it prints `plan OK`:

```bash
python3 - saves/edit_plan.json "$DUR" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1])); dur = float(sys.argv[2])
assert p["caption_groups"], "no caption groups"
assert abs(p["caption_groups"][-1]["end"] - dur) < 3.0, "captions do not cover the bed"
assert not re.search(r'[ऀ-ॿ]', json.dumps(p)), "Devanagari in plan — Latin script only"
for k in ("bg", "accent", "fg"):
    assert re.fullmatch(r'#[0-9A-Fa-f]{6}', p["brand"][k]), f"brand.{k} must be a single-# 6-digit hex"
tks = p.get("takeovers", [])
for tk in tks: assert 2.5 <= tk["end"] - tk["start"] <= 7, f"bad takeover window {tk}"
for a, b in zip(tks, tks[1:]):
    assert b["start"] - a["end"] >= 4, f"<4s of speaker between takeovers {a['end']}→{b['start']}"
    assert a["template"] != b["template"], "same template twice in a row"
assert all(tk["end"] <= dur - 2 for tk in tks), "takeover inside the final 2s"
cover_t = float(p.get("cover_at", dur * 0.4))
assert cover_t >= 2.0, f"cover_at={cover_t} is inside the hook — must be >= 2s"
assert not any(tk["start"] <= cover_t <= tk["end"] for tk in tks), "cover_at falls inside a takeover"
for g in p["caption_groups"]:
    assert sum(1 for w in g["words"] if w.get("em")) <= 1, "more than one emphasis word in a group"
print(f"plan OK: {len(p['caption_groups'])} groups, {len(tks)} takeovers, {len(p.get('sfx',[]))} sfx, cover_at={cover_t}s")
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. If `prior/transcripts.json` has too few
words to caption (fewer than ~10), exit non-zero with one plain line; the harness handles it.

## Checks the harness runs

- `plan_valid` — `saves/edit_plan.json` parses and satisfies the same guard as above: caption
  groups cover the bed to within 3 s, Latin script only, 6-digit brand hexes, every takeover
  2.5–7 s, `cover_at ≥ 2 s`.
