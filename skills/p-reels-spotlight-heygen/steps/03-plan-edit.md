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
   Takeover text names only the order's brand (WI2.95): quote the speech word for word, or write the
   order's brand in place of any other brand or product the clip names; never invent a brand, and
   never write a competitor or comparison line that names another brand (`X vs Y`, `better than X`).
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

Keep takeover text on the order's brand (WI2.95). A clip may name another brand or product (a CFW
promo cut for a `Test Brand` order says `CFW already learned her voice`). A takeover line of 3+ words
that quotes the speech word for word keeps it. Any other line that carries a spoken acronym (also
spelled out, `C F W`) or CamelCase name (`CFW`, `HubSpot`) the order does not own gets the order's
brand instead (`inputs/cta/cta.json` `brandName`, else `brief.json` `brand.name`, as on the end card),
or loses the name when the order has no brand. Generic acronyms (`CAC`, `MLS`, `HOA`, `NYC`, `PhD`),
`iPhone`-style words and names like `McKenzie` are never swapped. Write the helper, then run it on
the plan; it prints each line it changed.

```bash
mkdir -p work saves
cat > work/takeover_brand.py <<'PY'
# WI2.95: takeover text names only the order's brand, unless it quotes the speech word for word.
# usage: python3 work/takeover_brand.py PLAN.json WORDS.json [BRAND]          (repair takeovers in place)
#        python3 work/takeover_brand.py --check PLAN.json WORDS.json [BRAND]  (exit 1 on a foreign name)
# BRAND is the order's brand name ("" = the order has none). Without it the brand comes from the
# step workdir: inputs/cta/cta.json brandName, else brief.json brand.name (as the end card does).
# A foreign name is a brand-like word the speech says that the order does not own: an acronym (CFW,
# also spelled out "C F W") or a CamelCase word (HubSpot). It is never a generic acronym (AI, CAC,
# MLS, HOA, NYC, PhD, ...), a channel or tool (Instagram, iPhone, ...), a word that starts lower case
# (iOS, eBay) or a Mc/Mac/O'/De/Le name (McKenzie). A line of 3+ words that is an exact run of
# transcript words (case and punctuation aside) is a quote and keeps its words, unless the foreign
# name is most of it. Otherwise the name becomes the order's brand; with no order brand it is dropped.
# A brand is never invented. When in doubt a word is left alone: rule 5 asks the planner for the rest.
import html, json, os, re, sys

TOKEN = re.compile(r"[A-Za-z0-9]+(?:['’.&-][A-Za-z0-9]+)*")
TAG = re.compile(r"(<[^>]*>)")
POSS = re.compile(r"['’]s$", re.I)
NAME_PREFIX = re.compile(r"^(?:Mc|Mac|O['’]|D['’]|De|Di|Da|Du|Le|La|Van|Von|St)[A-Z]")
SKIP = {"tk-typing-ui": {"LABEL", "TYPING_SPEED"}}
HTML_KEYS = {"TITLE", "QUOTE"}
MIN_QUOTE = 3
# Never a competing brand: generic business, marketing, finance, real-estate, place and tech
# acronyms, and the channels / tools a reel talks about.
GENERIC = set("""
i ok ai api apis ceo ceos cto cfo coo cmo cro vp svp evp md phd mba cpa cfa jd rn pa hr pr it qa
diy faq faqs pdf url sms dm dms fyi asap eta tbh imo lol omg vip am pm est pst cst mst utc
q1 q2 q3 q4 ytd mtd yoy qoq mom b2b b2c d2c dtc smb smbs saas crm cms erp kpi kpis okr okrs roi
roas aov ltv cac cpc cpm cpa cpl ctr cvr ppc sem seo ugc cta ctas mrr arr gmv nps sop sops mvp
llc inc ltd co corp plc nda llp gst vat irs ira etf ipo sba fico heloc dti pmi apr apy arm emi gdp
usd eur gbp cad aud inr jpy cny
mls hoa fha va usda adu adus hvac reo nar cma hud fsbo noi reit reits sqft sf bd ba ac gc hoas
usa us uk eu uae nyc la sf dc nj ny ca tx fl wa nc ga az co il ma pa oh mi uk gta bc on nsw
tv hd uhd 4k 8k pc ios os wifi usb gps app apps vr ar xr iot gpu cpu ram ssd llm llms gpt ml nft nfts
btc eth qr id ip sdk ui ux js css html sql aws gcp
instagram ig tiktok youtube yt linkedin facebook fb threads pinterest reddit x twitter whatsapp
snapchat google gmail chatgpt claude gemini openai anthropic iphone ipad android macbook mac zoom
slack excel outlook zillow
""".split())
# Common words a transcript may put in capitals for emphasis ("NO", "STOP"): never a brand name.
COMMON = set("""
no so go do we me my he be by us or an at on in to up of if is it as yes now new top big best free win
wow stop look this that what when why how who you your our all one two ten get got see the and but not
just more most less real true easy fast huge done love hate need want must never ever only
""".split())


def norm(t):
    return re.sub(r"[^a-z0-9']", "", t.lower().replace("’", "'"))


def base(t):
    return norm(POSS.sub("", t))


def shaped(t):
    """an acronym (2-6 capitals, no lower case) or CamelCase word (HubSpot), by its own spelling;
    never a lower-case-first word (iPhone, iOS) or a Mc/Mac/O'/De/Le name (McKenzie)"""
    b = POSS.sub("", t)
    if not b[:1].isupper() or NAME_PREFIX.match(b):
        return False
    letters = re.sub(r"[^A-Za-z]", "", b)
    if 2 <= len(letters) <= 6 and letters.isupper():
        return True
    return bool(re.fullmatch(r"[A-Z][a-z]+(?:[A-Z][a-z0-9]*)+", b))


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
    """the transcript's plain tokens, the brand-like names it speaks, and its spelled-out letter runs"""
    toks, raw, stops, names, letters = [], [], [], set(), []
    for w in words:
        t = str(w.get("text", w.get("w", w.get("word", "")))) if isinstance(w, dict) else str(w)
        for m in TOKEN.finditer(t):
            toks.append(norm(m.group(0)))
            raw.append(m.group(0))
            stops.append(bool(re.match(r"\s*[.!?,;:…]", t[m.end():])))   # punctuation ends a run
    caps = [bool(re.search(r"[A-Z]", r)) and not re.search(r"[a-z]", r) and len(r) > 1 for r in raw]
    plainly = {b for r, b in zip(raw, toks) if not r.isupper()}
    for k, r in enumerate(raw):
        if not shaped(r):
            continue
        # an all-caps run of 2+ words ("NYC TEAM", "SO GOOD") is emphasis, and a word also said in
        # lower case is an ordinary word: neither is a name
        if caps[k] and ((k and caps[k - 1] and not stops[k - 1]) or (k + 1 < len(raw) and caps[k + 1] and not stops[k])
                        or base(r) in plainly):
            continue
        if base(r) not in COMMON:
            names.add(base(r))
    run = []
    for t in toks + [""]:   # "C F W" spoken letter by letter: every 3+ letter run is a name
        if len(t) == 1 and t.isalpha() and t not in ("a", "i"):
            run.append(t)
            continue
        for i in range(len(run)):
            for j in range(i + 3, len(run) + 1):
                letters.append("".join(run[i:j]))
        run = []
    return toks, names, set(letters)


def all_caps(value):
    letters = re.sub(r"[^A-Za-z]", "", plain(value))
    return bool(letters) and letters.isupper()


def foreign(value, names, spelled, own):
    """the foreign names in this line: a spoken name written as an acronym / CamelCase word (or in an
    all-caps word), or a spelled-out letter run ("C F W") written as an acronym"""
    out = []
    for m in TOKEN.finditer(plain(value)):
        tok, b = m.group(0), base(m.group(0))
        if not b or b in own or b in GENERIC or b in COMMON or not re.search(r"[a-z]", b):
            continue
        bare = POSS.sub("", tok)
        if not bare[:1].isupper() or NAME_PREFIX.match(bare):
            continue
        upper = re.sub(r"[^A-Za-z]", "", bare).isupper()
        if (b in names and (upper or shaped(bare))) or (b in spelled and upper and len(b) >= 3):
            out.append(tok)
    return out


def quoted(value, said, hits):
    toks = [t for t in (norm(t) for t in TOKEN.findall(plain(value))) if t]
    if len(toks) < MIN_QUOTE or 2 * len(hits) > len(toks):
        return False
    return (" " + " ".join(toks) + " ") in (" " + " ".join(said) + " ")


def fix_text(seg, names_hit, brand, caps):
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
        poss = POSS.search(toks[j].group(0))
        out.append(seg[pos:m.start()])
        pos = toks[j].end()
        if brand:
            out.append((brand.upper() if caps else brand) + (poss.group(0) if poss else ""))
        else:
            # drop the name and the space after it (or before it at the end)
            if seg[pos:pos + 1].isspace():
                pos += 1
            elif out and out[-1][-1:].isspace():
                out[-1] = out[-1][:-1]
        i = j + 1
    out.append(seg[pos:])
    return "".join(out)


def fix_value(value, names_hit, brand, is_html):
    caps = all_caps(value)
    if not is_html:
        return re.sub(r"\s{2,}", " ", fix_text(value, names_hit, brand, caps)).strip()
    hit = {base(t) for t in names_hit}
    parts = []
    for p in TAG.split(value):
        if TAG.fullmatch(p):
            parts.append(p)
            continue
        text = html.unescape(p)   # tokenise the text as shown (CFW&nbsp;writes is CFW + writes)
        if not any(base(t) in hit for t in TOKEN.findall(text)):
            parts.append(p)
            continue
        parts.append(html.escape(fix_text(text, names_hit, brand, caps), quote=False).replace("\xa0", "&nbsp;"))
    new = re.sub(r"<span[^>]*>\s*</span>", "", "".join(parts))
    return re.sub(r"[ \t]{2,}", " ", new).strip()


def problems(plan, said, names, spelled, own):
    bad = []
    for i, tk in enumerate(plan.get("takeovers") or []):
        fill = tk.get("fill") if isinstance(tk, dict) else None
        if not isinstance(fill, dict):
            continue
        skip = SKIP.get(tk.get("template"), set())
        for key, v in fill.items():
            if key in skip or not isinstance(v, str):
                continue
            hits = foreign(v, names, spelled, own)
            if hits and not quoted(v, said, hits):
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
    said, names, spelled = transcript(words)
    own = {base(t) for t in TOKEN.findall(brand)}
    bad = problems(plan, said, names, spelled, own)
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
    left = problems(plan, said, names, spelled, own)
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
assert subprocess.run([sys.executable, "work/caption_phrases.py", "--check", sys.argv[1]]).returncode == 0, \
    "a caption group splits a phrase mid-clause (WI2.76) — run python3 work/caption_phrases.py saves/edit_plan.json"
assert __import__("subprocess").run([sys.executable, "work/takeover_brand.py", "--check", sys.argv[1], "work/words.json"]).returncode == 0, \
    "takeover text names a brand the order does not own (WI2.95) — run python3 work/takeover_brand.py saves/edit_plan.json work/words.json"
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
