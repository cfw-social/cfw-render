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

1. `caption_groups` cover the FULL duration, 2–4 words each (up to 6 to keep a phrase whole),
   non-overlapping, breaking at punctuation, clause starts or pauses ≥ 150 ms. Never break after a
   preposition, article, possessive, conjunction or auxiliary (`with`, `of`, `the`, `her`, `and`,
   `is`, …), and never
   leave a lone 1–2 word fragment from mid-clause (`She approved them` / `with flour still on her
   hands,` — not `She approved them with` / `FLOUR STILL` / `on her hands,`). Words VERBATIM from
   the transcript.
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

Keep caption phrases whole (WI2.76). Write the helper, then run it on the plan: it moves a
group-ending preposition, article, conjunction or auxiliary into the next group, merges a
1–2 word mid-clause fragment into a neighbour (up to 6 words to keep a phrase whole), keeps
every word timing, and re-checks styles and emphasis. A plan that is already whole keeps its
groups; equal neighbouring styles, an overlap or a second emphasis word are still fixed (WI2.78).

```bash
mkdir -p work saves
cat > work/caption_phrases.py <<'PY'
# WI2.76: keep caption phrases whole - never split a group mid-clause.
# usage: python3 work/caption_phrases.py PLAN.json           (repair caption_groups in place)
#        python3 work/caption_phrases.py --check PLAN.json   (exit 1 when a group splits a phrase)
# A break never follows a preposition, article, conjunction or auxiliary (the trailing word
# moves to the next group). A 1-2 word group from mid-clause (no punctuation before it or after
# it) merges into a neighbour. Groups stay 2-4 words where they were; up to 6 to keep a phrase
# whole (a longer one is split at punctuation or a clause start). Word timings never change.
# WI2.78: repair mode also fixes adjacent equal styles, a group overlap and a second emphasis
# word on a plan that is already whole; a possessive ("her", "his") joins the next word.
# WI2.79: both modes refuse a group whose end is not after its start, or whose start is not
# after the previous group's start - an overlap is clamped only when the groups are in order.
import json, os, re, sys

MAX_WORDS = 6
JOINERS = set((
    "a an the my your our their its his her every each "
    "and but or nor so yet if than because while "
    "with of to in on at for from by into onto about as like through over under after before "
    "between among during without within until upon via toward towards near against across "
    "is am are was were be been being will would can could shall should may might must").split())
CLOSERS = ".,!?;:—–…"
CONTRACTION = re.compile(r"[a-z]('s|'re|'ve|'ll|'d|'m)$")

def text(w):
    return str(w.get("w", w.get("text", "")))

def bare(w):
    t = text(w).strip().lower().replace("’", "'")
    return re.sub(r"^[^a-z0-9']+|[^a-z0-9']+$", "", t)

def closes(w):
    # the word ends a clause: trailing punctuation (quotes/brackets ignored)
    t = re.sub(r"[\"'”’)\]]+$", "", text(w).strip())
    return bool(t) and t[-1] in CLOSERS

def joiner(w):
    if closes(w):
        return False
    b = bare(w)
    return b in JOINERS or bool(CONTRACTION.search(b))

def empty_groups(groups):
    # WI2.78: a group without words cannot be checked or repaired - say so plainly
    return ["group %d has no words - every caption group needs at least one word" % i
            for i, g in enumerate(groups) if not g.get("words")]

def num(v):
    try:
        return None if isinstance(v, bool) else float(v)
    except (TypeError, ValueError):
        return None

def timing_problems(groups):
    # WI2.79: clamping an overlap is only safe when every group runs forward in time and
    # the groups are in order; otherwise say so plainly (no clamp to end <= start)
    out, prev = [], None
    for i, g in enumerate(groups):
        s, e = num(g.get("start")), num(g.get("end"))
        if s is None or e is None:
            out.append("group %d has no start/end time (start=%r, end=%r) - every caption group "
                       "needs numeric start and end" % (i, g.get("start"), g.get("end")))
            prev = None
            continue
        if e <= s:
            out.append("group %d ends at %s, not after its start %s - a group must end after it starts"
                       % (i, g.get("end"), g.get("start")))
        if prev is not None and s <= prev:
            out.append("group %d starts at %s, not after group %d (starts at %s) - caption groups "
                       "must be in time order" % (i, g.get("start"), i - 1, groups[i - 1].get("start")))
        prev = s
    return out

def structure_problems(groups):
    # a plan these cannot be checked or repaired safely: no words, no/bad timings
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        return ["caption_groups is not a list of groups"]
    return empty_groups(groups) or timing_problems(groups)

def fragment(groups, i):
    # a 1-2 word group with no clause break before it and none after it
    g = groups[i]["words"]
    if not (0 < i < len(groups) - 1) or len(g) > 2:
        return False
    return not closes(groups[i - 1]["words"][-1]) and not closes(g[-1])

def bad_break(groups, i):
    # the break after group i falls inside a phrase
    return i < len(groups) - 1 and joiner(groups[i]["words"][-1])

def problems(groups):
    out = structure_problems(groups)
    if out:
        return out
    for i, g in enumerate(groups):
        ws = g.get("words") or []
        say = " ".join(text(w) for w in ws)
        if len(ws) > MAX_WORDS + 1:
            out.append("group %d has %d words: %r" % (i, len(ws), say))
        if fragment(groups, i):
            out.append("group %d is a mid-clause fragment: %r" % (i, say))
        if bad_break(groups, i):
            out.append("group %d ends inside a phrase: %r | %r" % (
                i, say, " ".join(text(w) for w in groups[i + 1]["words"])))
        if sum(1 for w in ws if w.get("em")) > 1:
            out.append("group %d has more than one emphasis word" % i)
        if i and g.get("style") == groups[i - 1].get("style"):
            out.append("groups %d and %d share style %s" % (i - 1, i, g.get("style")))
        if i and float(g["start"]) < float(groups[i - 1]["end"]) - 1e-6:
            out.append("group %d overlaps group %d" % (i, i - 1))
    return out

def split_long(ws):
    # best cut of an over-long group: after punctuation, else before a clause start,
    # never leaving a phrase-ending word on the left, both sides >= 3 words
    best = None
    for k in range(3, len(ws) - 2):
        left = ws[k - 1]
        if joiner(left):
            continue
        score = (0 if closes(left) else 1 if bare(ws[k]) in JOINERS else 2, abs(len(ws) - 2 * k))
        if best is None or score < best[0]:
            best = (score, k)
    return None if best is None else best[1]

def repair(groups):
    groups = [dict(g, words=[dict(w) for w in (g.get("words") or [])]) for g in groups]
    changed = False
    for _ in range(200):
        moved = False
        # fragments first, then phrase-ending breaks, then over-long groups
        frag = [i for i in range(len(groups)) if fragment(groups, i)]
        brk = [i for i in range(len(groups)) if bad_break(groups, i)]
        order = frag[:1] or brk[:1] or range(len(groups))
        for i in order:
            if fragment(groups, i):
                prev_n, next_n = len(groups[i - 1]["words"]), len(groups[i + 1]["words"])
                j = i - 1 if prev_n < next_n else i + 1
                lo, hi = min(i, j), max(i, j)
                groups[lo]["words"] += groups[hi]["words"]
                groups[lo]["_new"] = changed = True; del groups[hi]
                moved = True; break
            if bad_break(groups, i):
                a, b = groups[i], groups[i + 1]
                while a["words"] and joiner(a["words"][-1]):
                    b["words"].insert(0, a["words"].pop())
                a["_new"] = b["_new"] = changed = True
                if not a["words"]:
                    del groups[i]
                moved = True; break
            if len(groups[i]["words"]) > MAX_WORDS:
                k = split_long(groups[i]["words"])
                if k is None:
                    continue
                g = groups[i]
                tail = dict(g, words=g["words"][k:]); g["words"] = g["words"][:k]
                groups.insert(i + 1, tail); g["_new"] = tail["_new"] = changed = True
                moved = True; break
        if not moved:
            break
    for g in groups:
        if g.pop("_new", False):
            g["start"], g["end"] = g["words"][0]["s"], g["words"][-1]["e"]
    return groups, changed

def restyle(groups):
    for i, g in enumerate(groups):
        prev = groups[i - 1].get("style") if i else None
        if g.get("style") == prev:
            nxt = groups[i + 1].get("style") if i + 1 < len(groups) else None
            g["style"] = next(s for s in (0, 1, 2) if s not in (prev, nxt))

def tidy(groups):
    # WI2.78: run on every plan, regrouped or not - at most one emphasis word per group,
    # no group overlaps the next (its end moves back, word timings never move), no two
    # neighbours share a style
    for g in groups:
        seen = False
        for w in g["words"]:
            if w.get("em"):
                if seen:
                    w["em"] = False
                seen = True
    for a, b in zip(groups, groups[1:]):
        if float(a["end"]) > float(b["start"]):
            a["end"] = b["start"]
    restyle(groups)

def run(plan):
    orig = plan.get("caption_groups") or []
    if not orig:
        return plan, False
    bad = structure_problems(orig)
    if bad:
        raise ValueError("; ".join(bad))
    first_start, last_end = orig[0]["start"], orig[-1]["end"]
    groups, regrouped = repair(orig)
    if regrouped:
        groups[0]["start"] = min(float(groups[0]["start"]), float(first_start))
        groups[-1]["end"] = max(float(groups[-1]["end"]), float(last_end))
    tidy(groups)
    if not regrouped and groups == orig:
        return plan, False
    plan = dict(plan, caption_groups=groups)
    return plan, True

def stop(msg):
    print("caption phrase check: " + msg, file=sys.stderr)
    sys.exit(1)

if __name__ == "__main__":
    args = sys.argv[1:]
    check = args[:1] == ["--check"]
    if len(args) != (2 if check else 1):
        stop("usage: caption_phrases.py [--check] PLAN.json (WI2.79)")
    path = args[-1]
    if not os.path.isfile(path):
        stop("plan not found: %s - write the plan before this step (WI2.79)" % path)
    try:
        plan = json.load(open(path))
    except ValueError as exc:
        stop("plan is not valid JSON: %s (%s) (WI2.79)" % (path, exc))
    if not isinstance(plan, dict):
        stop("plan is not a JSON object: %s (WI2.79)" % path)
    structural = structure_problems(plan.get("caption_groups") or [])
    if structural:
        for b in structural:
            print("caption phrase check: " + b, file=sys.stderr)
        sys.exit(1)
    if not check:
        before = [" ".join(text(w) for w in g.get("words") or []) for g in plan.get("caption_groups") or []]
        plan, changed = run(plan)
        if changed:
            json.dump(plan, open(path, "w"), indent=1)
            after = [" ".join(text(w) for w in g["words"]) for g in plan["caption_groups"]]
            if after == before:
                print("[plan] caption phrases: groups kept, styles/overlaps/emphasis fixed")
            else:
                print("[plan] caption phrases: regrouped %d -> %d groups" % (len(before), len(after)))
            for line in sorted(set(after) - set(before), key=after.index):
                print("  [%s]" % line)
        else:
            print("[plan] caption phrases: already whole, plan unchanged")
    bad = problems(plan.get("caption_groups") or [])
    for b in bad:
        print("caption phrase check: " + b, file=sys.stderr)
    sys.exit(1 if bad else 0)
PY
```

```bash
python3 work/caption_phrases.py saves/edit_plan.json || exit 1
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
assert subprocess.run([sys.executable, "work/caption_phrases.py", "--check", sys.argv[1]]).returncode == 0, \
    "a caption group splits a phrase mid-clause (WI2.76) — run python3 work/caption_phrases.py saves/edit_plan.json"
print(f"plan OK: {len(p['caption_groups'])} groups, {len(tks)} takeovers, {len(p.get('sfx',[]))} sfx, cover_at={cover_t}s")
PY
```

## If you cannot proceed

This step has no `canAsk`. Never write `needs_input.json`. If `prior/transcripts.json` has too few
words to caption (fewer than ~10), exit non-zero with one plain line; the harness handles it.

## Checks the harness runs

- `plan_valid` — `saves/edit_plan.json` parses and satisfies the same guard as above: caption
  groups cover the bed to within 4.5 s (its silent end-card tail, WI2.89) and keep phrases whole, Latin script only, 6-digit brand
  hexes, every takeover 2.5–7 s, `cover_at ≥ 2 s`.
