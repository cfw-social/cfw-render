# Write the post captions

Write the post copy once per target platform, in the brand voice, from the slide copy that was
actually rendered — same hook, same numbers, same CTA, never new claims. A carousel with no
caption cannot be published.

## You receive

- `prior/slide_copy.json` — the rendered copy (`slides[]` with `headline`, `body`, `role`).
- `prior/slides.json` — `count` (how many slides the reader will see).
- `inputs/cta/cta.json` — optional `{"text","brandName","handle"}`.
- `brief.json` — `targets` (platform list), `brand` (name, brief text / voice), `intent`.

## You must produce

- `saves/captions.json` — ONE JSON object keyed by lower-cased platform name, one key per
  platform in `brief.json.targets` plus `default`:

```json
{
  "default":   "<hook + 2–4 lines + CTA>",
  "linkedin":  "<3–6 short paragraphs; hashtags only at the end, ≤ 3000 chars>",
  "instagram": "<hook + 2–4 lines + CTA + 3–8 hashtags, ≤ 2200 chars>",
  "facebook":  "<the Instagram body without the hashtag block>",
  "threads":   "<≤ 500 chars, conversational, ≤ 2 hashtags>",
  "twitter":   "<≤ 280 chars, hook-first, no hashtags>"
}
```

## How

`mkdir -p work saves`.

### 1. Read what was rendered

```bash
python3 - <<'PY'
import json
c = json.load(open('prior/slide_copy.json')); b = json.load(open('brief.json'))
print("targets:", b.get("targets")); print("brand:", b["brand"].get("name"))
for s in c["slides"]: print(s["n"], s["role"], "|", s["headline"], "|", s.get("body",""))
PY
cat inputs/cta/cta.json 2>/dev/null
```

### 2. Write each caption

- **Hook line** matches the cover slide's headline (same promise, same words where possible).
- **Tease** slides 2–3 — do not give the whole set away.
- **CTA** — "Save this + follow for more", plus `cta.text` when supplied. Mention the brand by
  `cta.brandName` / `brief.json.brand.name`; add the handle ONLY when `cta.handle` exists.
- **Hashtags** — 3–5 relevant ones where the platform takes them: none at the start on
  LinkedIn, none on X/Twitter, ≤ 2 on Threads.
- Platform limits as in the shape above. Latin script only, no kitchen words, no claims that
  are not on a slide.

### 3. Write the save and self-check

```bash
python3 - <<'PY'
import json
b = json.load(open('brief.json')); d = json.load(open('work/captions.json'))
want = {t.lower() for t in b.get("targets", [])} | {"default"}
missing = want - set(d); assert not missing, f"missing captions for {sorted(missing)}"
assert all(isinstance(v, str) and v.strip() for v in d.values()), "blank caption"
limits = {"twitter": 280, "threads": 500, "instagram": 2200, "linkedin": 3000}
for k, v in d.items():
    assert len(v) <= limits.get(k, 3000), f"{k} caption too long ({len(v)})"
    if k in ("twitter",): assert "#" not in v, "no hashtags on twitter"
json.dump(d, open('saves/captions.json', 'w'), indent=1, ensure_ascii=False)
print(f"[carousel] captions for {sorted(d)}")
PY
```

## If you cannot proceed

This step has no `canAsk` (`cta` defaults to the brand). Never write `needs_input.json`. An
empty `targets` list still gets a `default` caption; a slide copy that does not parse is a
failure: exit non-zero with one plain line.

## Checks the harness runs

- `captions_per_target` — `saves/captions.json` parses to an object with a non-blank string
  for `default` and for every platform in `brief.json.targets`, within the per-platform length
  limits.
