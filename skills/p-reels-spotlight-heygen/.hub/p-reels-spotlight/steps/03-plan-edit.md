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
LABEL (e.g. `claude.ai`), PROMPT (the typed text), TYPING_SPEED (0.5–1.5), BOTTOM_TAG, and
optionally CARD_LABEL (the line above the card; default `The prompt`).

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
   Takeover text names only the order's brand (WI2.95): quote the speech word for word, or write the
   order's brand in place of any other brand or product the clip names; never invent a brand.
6. `sfx`: `whoosh-deep` at every takeover start, `impact-sub` 0.4 s later, optional `riser` 1.5 s
   before the biggest takeover, `click`/`pop` on at most 3 emphasis words. Max 12 cues, gain ≤ 0.6.
7. `cover_at`: a mid-content frame (ideally mid-sentence at peak energy) — NEVER t=0 or the first
   3 s. Typically 20–60 % of the duration, and not inside a takeover window (the cover must show
   the speaker).
8. A visible change (takeover, emphasis pop or caption style shift) every 2–4 seconds.
9. `grade`: honour `brief.json.options.grade` when set; otherwise pick `warm-amber` for warm /
   personal content and `clean-bright` for product / tech content.

Keep takeover text on the order's brand (WI2.95). A clip may name another brand or product (a CFW
promo cut for a `Test Brand` order says `CFW already learned her voice`). A takeover line that quotes
the speech word for word keeps it. Any other line that carries a spoken acronym or CamelCase name
(`CFW`, `HubSpot`) the order does not own gets the order's brand instead (`inputs/cta/cta.json`
`brandName`, else `brief.json` `brand.name`, as on the end card), or loses the name when the order
has no brand. Write the helper, then run it on the plan; it prints each line it changed.

```bash
mkdir -p work saves
cat > work/takeover_brand.py <<'PY'
# WI2.95: takeover text names only the order's brand, unless it quotes the speech word for word.
# usage: python3 work/takeover_brand.py PLAN.json WORDS.json [BRAND]          (repair takeovers in place)
#        python3 work/takeover_brand.py --check PLAN.json WORDS.json [BRAND]  (exit 1 on a foreign name)
# BRAND is the order's brand name ("" = the order has none). Without it the brand comes from the
# step workdir: inputs/cta/cta.json brandName, else brief.json brand.name (as the end card does).
# A takeover line that is an exact run of transcript words (case and punctuation aside) is a quote
# and is kept. Any other line may not carry a brand-like name the order does not own: an acronym or
# CamelCase word the speech says (CFW, HubSpot) or a CamelCase word in the line. With an order brand
# the name becomes that brand; with none it is dropped. A brand is never invented. Generic acronyms
# (AI, CEO, ...) and the channels a reel talks about (Instagram, TikTok, ...) are not brands here.
import html, json, os, re, sys

TOKEN = re.compile(r"[A-Za-z0-9]+(?:['’.&-][A-Za-z0-9]+)*")
TAG = re.compile(r"(<[^>]*>)")
POSS = re.compile(r"['’]s$", re.I)
SKIP = {"tk-typing-ui": {"LABEL", "TYPING_SPEED"}}
HTML_KEYS = {"TITLE", "QUOTE"}
# Generic acronyms and the channels / tools a reel talks about: never a competing brand.
GENERIC = set("""i ai api apis ceo cto cfo coo cmo diy faq seo roi kpi kpis crm saas b2b b2c dm dms pr hr it ui ux
url pdf ok tv usa uk eu us am pm mvp llm llms gpt cta ctas asap fyi q1 q2 q3 q4 ugc ar vr id ip sms
instagram ig tiktok youtube yt linkedin facebook fb threads pinterest reddit x twitter whatsapp snapchat google
chatgpt claude gemini openai anthropic""".split())


def norm(t):
    return re.sub(r"[^a-z0-9']", "", t.lower().replace("’", "'"))


def base(t):
    return norm(POSS.sub("", t))


def shaped(t):
    # an acronym (2+ capitals, no lower case) or CamelCase word, by its own spelling
    b = POSS.sub("", t)
    letters = re.sub(r"[^A-Za-z]", "", b)
    if len(letters) >= 2 and letters.isupper():
        return True
    return bool(re.search(r"[a-z][A-Z]", b))


def plain(v):
    return html.unescape(TAG.sub(" ", v))


def stop(msg):
    print("takeover brand check: " + msg, file=sys.stderr)
    sys.exit(1)


def order_brand():
    cta = {}
    if os.path.isfile("inputs/cta/cta.json"):
        cta = json.load(open("inputs/cta/cta.json"))
    if not os.path.isfile("brief.json") and not cta:
        stop("no order brand: pass BRAND, or run in the step workdir with brief.json (WI2.95)")
    brief = json.load(open("brief.json")) if os.path.isfile("brief.json") else {}
    b = (brief.get("brand") or {}) if isinstance(brief, dict) else {}
    return str((cta.get("brandName") if isinstance(cta, dict) else "") or b.get("name") or "").strip()


def transcript(words):
    """the transcript's plain tokens, and the brand-like names it speaks (acronyms, CamelCase)"""
    toks, names = [], set()
    for w in words:
        t = str(w.get("text", w.get("w", w.get("word", "")))) if isinstance(w, dict) else str(w)
        for m in TOKEN.finditer(t):
            toks.append(norm(m.group(0)))
            if shaped(m.group(0)):
                names.add(base(m.group(0)))
    return toks, names


def all_caps(value):
    letters = re.sub(r"[^A-Za-z]", "", plain(value))
    return bool(letters) and letters.isupper()


def foreign(value, names, own):
    """the names in this line that the order does not own"""
    out = []
    for m in TOKEN.finditer(plain(value)):
        tok, b = m.group(0), base(m.group(0))
        if not b or b in own or b in GENERIC or not re.search(r"[a-z]", b):
            continue
        if b in names or re.search(r"[a-z][A-Z]", POSS.sub("", tok)):
            out.append(tok)
    return out


def quoted(value, said):
    toks = [norm(t) for t in TOKEN.findall(plain(value))]
    toks = [t for t in toks if t]
    return bool(toks) and (" " + " ".join(toks) + " ") in (" " + " ".join(said) + " ")


def fix_text(seg, names_hit, brand, is_html, caps):
    hit = {base(t) for t in names_hit}
    toks = list(TOKEN.finditer(seg))
    out, pos, i = [], 0, 0
    while i < len(toks):
        m = toks[i]
        if base(m.group(0)) not in hit:
            i += 1
            continue
        j = i  # a run of adjacent names ("Acme Labs") is one name
        while j + 1 < len(toks) and base(toks[j + 1].group(0)) in hit and seg[toks[j].end():toks[j + 1].start()].strip() == "":
            j += 1
        last = toks[j].group(0)
        poss = POSS.search(last)
        out.append(seg[pos:m.start()])
        if brand:
            name = brand.upper() if caps else brand
            if is_html:
                name = html.escape(name)
            out.append(name + (poss.group(0) if poss else ""))
            pos = toks[j].end()
        else:
            pos = toks[j].end()
            # drop the name and the space after it (or before it at the end)
            rest = seg[pos:]
            if rest[:1] == " ":
                pos += 1
            elif out and out[-1].endswith(" "):
                out[-1] = out[-1][:-1]
        i = j + 1
    out.append(seg[pos:])
    return "".join(out)


def fix_value(value, names_hit, brand, is_html):
    caps = all_caps(value)
    if not is_html:
        return re.sub(r"\s{2,}", " ", fix_text(value, names_hit, brand, False, caps)).strip()
    parts = TAG.split(value)
    parts = [p if TAG.fullmatch(p) else fix_text(p, names_hit, brand, True, caps) for p in parts]
    new = "".join(parts)
    new = re.sub(r"<span[^>]*>\s*</span>", "", new)
    return re.sub(r"[ \t]{2,}", " ", new).strip()


def problems(plan, said, names, own):
    bad = []
    for i, tk in enumerate(plan.get("takeovers") or []):
        fill = tk.get("fill") if isinstance(tk, dict) else None
        if not isinstance(fill, dict):
            continue
        skip = SKIP.get(tk.get("template"), set())
        for key, v in fill.items():
            if key in skip or not isinstance(v, str):
                continue
            hits = foreign(v, names, own)
            if hits and not quoted(v, said):
                bad.append((i, key, v, hits))
    return bad


def main(argv):
    check = argv[:1] == ["--check"]
    args = argv[1:] if check else argv
    if len(args) not in (2, 3):
        stop("usage: takeover_brand.py [--check] PLAN.json WORDS.json [BRAND] (WI2.95)")
    path, wpath = args[0], args[1]
    brand = args[2].strip() if len(args) == 3 else order_brand()
    for p in (path, wpath):
        if not os.path.isfile(p):
            stop("file not found: %s (WI2.95)" % p)
    try:
        plan, words = json.load(open(path)), json.load(open(wpath))
    except ValueError as exc:
        stop("not valid JSON: %s (WI2.95)" % exc)
    if isinstance(words, dict):
        words = words.get("words") or []
    if not isinstance(plan, dict) or not isinstance(words, list):
        stop("plan must be a JSON object and words a JSON list (WI2.95)")
    said, names = transcript(words)
    own = {base(t) for t in TOKEN.findall(brand)}
    bad = problems(plan, said, names, own)
    if check:
        for i, key, v, hits in bad:
            print("takeover brand check: takeover %d %s %r names %s, not the order brand %r, and is not a word-for-word "
                  "quote of the speech - quote the speech or use the order brand (WI2.95)"
                  % (i + 1, key, v, "/".join(hits), brand or "(none)"), file=sys.stderr)
        sys.exit(1 if bad else 0)
    for i, key, v, hits in bad:
        tk = plan["takeovers"][i]
        new = fix_value(v, hits, brand, key in HTML_KEYS)
        if not re.search(r"[A-Za-z0-9]", plain(new)):
            stop("takeover %d %s %r is only a foreign name; rewrite it from the speech (WI2.95)" % (i + 1, key, v))
        tk["fill"][key] = new
        print("[plan] takeover %d %s: %r -> %r (names %s; order brand %r)" % (i + 1, key, v, new, "/".join(hits), brand or "(none)"))
    if bad:
        json.dump(plan, open(path, "w"), indent=2)
    else:
        print("[plan] takeover brand: no foreign brand names, plan unchanged")
    left = problems(plan, said, names, own)
    for i, key, v, hits in left:
        print("takeover brand check: takeover %d %s %r still names %s (WI2.95)" % (i + 1, key, v, "/".join(hits)), file=sys.stderr)
    sys.exit(1 if left else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
PY
```

```bash
python3 work/takeover_brand.py saves/edit_plan.json work/words.json || exit 1
```

Then run the mechanical guard — fix the plan and rerun until it prints `plan OK`:

```bash
python3 - saves/edit_plan.json "$DUR" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1])); dur = float(sys.argv[2])
assert p["caption_groups"], "no caption groups"
# WI2.89: the bed ends in a silent end-card tail (at most 3.5 s), so allow 4.5 s.
assert abs(p["caption_groups"][-1]["end"] - dur) < 4.5, "captions do not cover the bed"
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
import subprocess
assert subprocess.run([sys.executable, "work/takeover_brand.py", "--check", sys.argv[1], "work/words.json"]).returncode == 0, \
    "takeover text names a brand the order does not own (WI2.95) — run python3 work/takeover_brand.py saves/edit_plan.json work/words.json"
print(f"plan OK: {len(p['caption_groups'])} groups, {len(tks)} takeovers, {len(p.get('sfx',[]))} sfx, cover_at={cover_t}s")
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. If `prior/transcripts.json` has too few
words to caption (fewer than ~10), exit non-zero with one plain line; the harness handles it.

## Checks the harness runs

- `plan_valid` — `saves/edit_plan.json` parses and satisfies the same guard as above: caption
  groups cover the bed to within 4.5 s (its silent end-card tail, WI2.89), Latin script only, 6-digit brand hexes, every takeover
  2.5–7 s, `cover_at ≥ 2 s`.
