#!/usr/bin/env python3
"""captions.py - the one caption builder, burner and checker for p-longform (B51).

Stdlib only (ffmpeg does the audio and picture work). Captions used to be written fresh by the engine
on every run, so every render had a different style and one lost its captions on more than half of the
speech. This file replaces that. The same transcript always gives the same bytes. The check does not
trust the transcript: it measures the speech from the narration audio itself.

Modes

  choice  Print `on` or `off`. Captions are ON unless something says off:
            1. inputs/captions/ (captions.json {"choice": ...}, or the first .md/.txt): `off`, `no`,
               `false`, `0` or `none` is off; any other text is on; an empty file counts as no answer;
            2. brief.json options.captions, when present (false / off is off);
            3. otherwise ON (a missing input is not a refusal).

  build   Write an ASS caption file from the transcript.
            --dir DIR           step workdir (brief.json, inputs/, prior/, work/); sets the defaults below
            --transcript F      prior/transcripts.json, or a .srt file;  --srt F  an SRT file
            --out F             work/captions.ass
            --end-card-start S  seconds; default = start of the last gfx:cta row of prior/broll_plan.json
            --accent #RRGGBB    active-word colour; default brief palette accent, else brand file, else #F97316
            --audio F           the narration, prior/composite_video.mp4 (only used to transcribe, see below)
            --transcribe-script F   speech-to-text script; default .hub/c-audio/scripts/transcribe.sh
          Every spoken word before the end card is captioned. The layout is never read. The words are the
          script-aligned `words` of transcripts.json PLUS the recognised words (`spoken_words`, saved by
          step 03) that fall in a real hole (a gap of 1.2 s or more between aligned words): words the
          speaker said that are not in the script. A recognised word that only sits 0.1-0.3 s off an
          aligned one is the same word and is not added twice. When
          a restored transcript has no `spoken_words`, the narration is transcribed here (offline whisper);
          if that cannot run, build stops and says why. Nothing starts at or after the end card, and a
          caption that is up then ends there. A transcript with only segments (or an SRT) is spread over
          each segment in proportion to the letters in each word.

  burn    Burn the caption file into the video with a fixed ffmpeg command: the bundled Inter Bold
          (fonts/, OFL) through an explicit fontsdir, never a downloaded font. Needs an ffmpeg that has
          the `ass` filter: $CFW_FFMPEG when it is set (and it must have the filter), else the one on PATH,
          else the ffmpeg-full install; if none does it stops and says so.
            --in work/loudnorm.mp4  --ass work/captions.ass  --out saves/mastered_video.mp4

  verify  Prove the caption file covers the speech.
            --ass F             work/captions.ass
            --audio F           prior/composite_video.mp4: the narration before the SFX bed
            --end-card-start S  as build
            --max-gap 3.0       longest stretch of speech with no caption, in seconds
            --min-cover 0.97    least share of speech time under a caption
          Speech time is the VOICED time of the narration audio (ffmpeg silencedetect, -35 dB, pauses
          under 0.5 s count as speech), up to the end card. It fails when speech runs longer than
          --max-gap without a caption, when under --min-cover of it is captioned, or when a caption is on
          screen over the end card. With --dir the owner's choice is read first: `off` passes, unless the
          brief's intent asks for captions, which fails (the brief and the choice disagree).

Exit 0 = pass, 1 = the check failed (one summary line last), 2 = it could not run.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys

SKILL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---- the fixed brand style (steps/07-post-process.md, "Captions") -------------------------------------
FONT, FONT_SIZE = "Inter", 56
FONT_FILE = "Inter-Bold.ttf"    # fonts/ in this recipe, SIL OFL 1.1 (fonts/OFL.txt)
MARGIN_X = 420                  # text stays inside x 420-1500: clear of both bottom PIP corners
MARGIN_V = 70                   # gap from the frame bottom; two lines of 56 px start near y 875 (CAP_TOP 820)
BOX_PAD = 10                    # px of backing box around the text
BOX_COLOUR = "&H002A170F"       # opaque dark navy (#0F172A) box; opaque so the seams between colour runs do not show
WHITE = "&H00FFFFFF"
DEFAULT_ACCENT = "#F97316"
# ---- grouping ---------------------------------------------------------------------------------------
MAX_WORDS = 7                   # words in one caption
MAX_CHARS = 62                  # letters and spaces in one caption (two lines)
LINE_CHARS = 30                 # a caption longer than this is split in two lines
PAUSE_BREAK = 0.6               # a pause this long between words starts a new caption
MAX_SPAN = 3.5                  # seconds one caption may stay up while words are spoken
LINGER = 0.6                    # a caption stays this long after its last word if nothing follows soon
MIN_EVENT = 0.04                # shortest event: one 25 fps frame
MIN_LAST = 0.25                 # the last word of a caption shows at least this long
MAX_WORD = 1.5                  # a word never counts as longer than this (an unspoken script word is spread over a gap)
HOLE_MIN_GAP = 1.2              # a recognised word is added only inside a gap this long between aligned words ...
HOLE_EDGE = 0.15                # ... and at least this far from both edges of the gap
NEAR_MATCH = 1.0                # a recognised word that spells an aligned word within this many seconds is the same word
# ---- the check --------------------------------------------------------------------------------------
SILENCE_DB = -35                # below this level the narration is silent (silencedetect)
SILENCE_MIN = 0.5               # silences shorter than this are pauses inside speech
MIN_VOICED = 0.25               # a voiced blip shorter than this is noise
MAX_GAP = 3.0
MIN_COVER = 0.97
CARD_OVERLAP = 0.10             # captions over the end card for more than this fail the check

SENTENCE_END = re.compile(r"[.?!][\"')\]]*$")
CLAUSE_END = re.compile(r"[,;:][\"')\]]*$")
TS_RE = re.compile(r"^(\d+):(\d{1,2}):(\d{1,2})[.,](\d{1,3})$")
SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,80}$")
OFF_RE = re.compile(r"^(off|no|false|0|none|disabled)\b")
ASKS_RE = re.compile(r"captions?|subtitles?", re.I)
NEGATION_RE = re.compile(r"\b(no|without|skip|not|don'?t|dont|never|off|remove|disable|exclude|excluding)\b", re.I)


class Usage(Exception):
    """The check could not run (bad or missing input). Exit 2."""


class Fail(Exception):
    """The check ran and the captions are not good enough. Exit 1."""


# ---- small helpers -----------------------------------------------------------------------------------

def read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except OSError as exc:
        raise Usage("cannot read %s (%s): %s" % (what, path, exc.strerror or exc))
    except ValueError as exc:
        raise Usage("%s (%s) is not valid JSON: %s" % (what, path, exc))


def fmt(t):
    """m:ss.s for messages."""
    t = max(float(t), 0.0)
    return "%d:%04.1f" % (int(t // 60), t - 60 * int(t // 60))


def parse_ts(text):
    m = TS_RE.match(text.strip())
    if not m:
        return None
    h, mi, s, frac = m.groups()
    return int(h) * 3600 + int(mi) * 60 + int(s) + float("0." + frac)


def hex_colour(value):
    return value.upper() if isinstance(value, str) and re.match(r"^#[0-9A-Fa-f]{6}$", value) else None


def ass_colour(hex6):
    r, g, b = hex6[1:3], hex6[3:5], hex6[5:7]
    return "&H00%s%s%s" % (b, g, r)


def cs_time(cs):
    return "%d:%02d:%02d.%02d" % (cs // 360000, cs // 6000 % 60, cs // 100 % 60, cs % 100)


def tail(text, n=300):
    return " ".join((text or "").split())[-n:]


# ---- the owner's choice -----------------------------------------------------------------------------

def _answer_text(workdir):
    """The text of the captions input, or None when there is no (non-empty) answer."""
    folder = os.path.join(workdir, "inputs", "captions")
    j = os.path.join(folder, "captions.json")
    if os.path.exists(j):
        data = read_json(j, "the captions choice")
        value = data.get("choice") if isinstance(data, dict) else None
        return str(value).strip() if value not in (None, "") and str(value).strip() else None
    for f in sorted(glob.glob(os.path.join(folder, "*"))):
        if f.endswith((".md", ".txt")):
            try:
                with open(f, encoding="utf-8") as fh:
                    value = fh.read().strip()
            except OSError as exc:
                raise Usage("cannot read the captions choice (%s): %s" % (f, exc.strerror or exc))
            return value or None
    return None


def _brief(workdir):
    path = os.path.join(workdir, "brief.json")
    data = read_json(path, "brief.json") if os.path.isfile(path) else {}
    return data if isinstance(data, dict) else {}


def captions_state(workdir):
    """(choice, source): `on` or `off`, and what decided it. ON unless an input or option says off."""
    answer = _answer_text(workdir)
    if answer is not None:
        return ("off" if OFF_RE.match(answer.lower()) else "on"), "the captions input"
    options = _brief(workdir).get("options")
    if isinstance(options, dict) and "captions" in options and options["captions"] not in (None, ""):
        value = options["captions"]
        off = value is False or (isinstance(value, str) and bool(OFF_RE.match(value.strip().lower())))
        return ("off" if off else "on"), "the captions option in brief.json"
    return "on", "the default (no captions input was given)"


def captions_choice(workdir):
    return captions_state(workdir)[0]


def intent_asks_for_captions(workdir):
    """The words of brief.json `intent` that ask for captions, or None."""
    intent = _brief(workdir).get("intent")
    if not isinstance(intent, str):
        return None
    for m in ASKS_RE.finditer(intent):
        before = intent[max(0, m.start() - 24):m.start()]
        if not NEGATION_RE.search(before):
            return " ".join(intent[max(0, m.start() - 30):m.end() + 20].split())
    return None


# ---- transcript -------------------------------------------------------------------------------------

def parse_srt(text):
    """[(start, end, text)] from SRT text."""
    out = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").replace("\r", "\n").strip()):
        lines = [ln for ln in block.split("\n") if ln.strip()]
        for k, ln in enumerate(lines):
            if "-->" in ln:
                a, _, b = ln.partition("-->")
                s, e = parse_ts(a), parse_ts(b.split()[0] if b.strip() else "")
                if s is not None and e is not None:
                    out.append((s, e, " ".join(x.strip() for x in lines[k + 1:])))
                break
    return out


def _row(item, *text_keys):
    if not isinstance(item, dict):
        return None
    text = next((item[k] for k in text_keys if isinstance(item.get(k), str)), None)
    try:
        s, e = float(item["start"]), float(item["end"])
    except (KeyError, TypeError, ValueError):
        return None
    if text is None or s != s or e != e or s < 0:
        return None
    return (s, max(e, s), text)


def word_rows(items):
    """[(start, end, text)] from a list of {w, start, end}; a word never counts as longer than MAX_WORD."""
    rows = [_row(w, "w", "word", "text") for w in items] if isinstance(items, list) else []
    return [(s, min(e, s + MAX_WORD), t) for s, e, t in (r for r in rows if r)]


def load_speech(path, force_srt=False):
    """The transcript at `path` as ([(start, end, text)], spoken_rows or None, kind).

    kind is `words` (a list of single words) or `segments`. spoken_rows are the recognised words
    (`spoken_words`), None when the file has none."""
    if force_srt or path.lower().endswith(".srt"):
        try:
            with open(path, encoding="utf-8") as fh:
                rows = parse_srt(fh.read())
        except OSError as exc:
            raise Usage("cannot read the transcript (%s): %s" % (path, exc.strerror or exc))
        if not rows:
            raise Usage("the SRT file (%s) has no timed lines" % path)
        return rows, None, "srt"
    data = read_json(path, "the transcript")
    rows, kind = [], "words"
    if isinstance(data, dict):
        if isinstance(data.get("words"), list) and data["words"]:
            rows = word_rows(data["words"])
        elif isinstance(data.get("segments"), list) and data["segments"]:
            rows, kind = [r for r in (_row(s, "text") for s in data["segments"]) if r], "segments"
        elif isinstance(data.get("srt"), str):
            rows, kind = parse_srt(data["srt"]), "segments"
        spoken = word_rows(data["spoken_words"]) if isinstance(data.get("spoken_words"), list) else None
    elif isinstance(data, list):
        rows, spoken = word_rows(data), None
    else:
        spoken = None
    if not rows:
        raise Usage("the transcript (%s) has no words, segments or srt with times" % path)
    return rows, spoken, kind


def clean_token(tok):
    return re.sub(r"[{}\\\x00-\x1f]", "", tok)


def to_words(rows):
    """[(token, start, end)]: one per whitespace-separated token; rows with several tokens (segments) are
    spread in proportion to the letters in each token."""
    words = []
    for s, e, text in sorted(rows, key=lambda r: (r[0], r[1])):
        toks = [clean_token(t) for t in text.split()]
        toks = [t for t in toks if t]
        if not toks:
            continue
        weights = [len(t) + 1 for t in toks]
        total, acc = float(sum(weights)), 0.0
        for t, w in zip(toks, weights):
            a = s + (e - s) * acc / total
            acc += w
            words.append((t, a, s + (e - s) * acc / total))
    return words


def norm_word(text):
    return re.sub(r"[^a-z0-9]", "", text.lower())


def fill_alignment_holes(rows, spoken):
    """The aligned rows plus the recognised words that fall in a real hole. Step 03 keeps only the script
    words it could align, so a speaker's extra words leave a hole: here they come back. Only a hole counts:
    whisper and the alignment often place the same word 0.1-0.3 s apart, and adding both would show it
    twice. So a recognised word is added only when it lies inside a gap of at least HOLE_MIN_GAP seconds
    between aligned words, at least HOLE_EDGE seconds from each edge of the gap, and it is dropped when it
    spells (ignoring case and punctuation) an aligned word within NEAR_MATCH seconds."""
    covered = merge([(s, e) for s, e, _ in rows])
    gaps, at = [], 0.0
    for a, b in covered:
        if a - at >= HOLE_MIN_GAP:
            gaps.append((at, a))
        at = max(at, b)
    gaps.append((at, float("inf")))                      # after the last aligned word
    aligned_text = [(s, e, {norm_word(t) for t in text.split()} - {""}) for s, e, text in rows]
    extra = []
    for s, e, text in spoken:
        if not any(s >= a + HOLE_EDGE and e <= b - HOLE_EDGE for a, b in gaps):
            continue
        n = norm_word(text)
        if n and any(n in toks for rs, re_, toks in aligned_text if re_ >= s - NEAR_MATCH and rs <= e + NEAR_MATCH):
            continue
        extra.append((s, e, text))
    return sorted(rows + extra, key=lambda r: (r[0], r[1])), len(extra)


def find_transcribe_script(explicit):
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    for cand in (os.path.join(SKILL_DIR, ".hub", "c-audio", "scripts", "transcribe.sh"),
                 os.path.join(os.path.dirname(SKILL_DIR), "c-audio", "scripts", "transcribe.sh")):
        if os.path.isfile(cand):
            return cand
    return None


def recognise_narration(audio, out_json, script):
    """Run the offline speech-to-text on the narration; returns [(start, end, word)]."""
    if not audio or not os.path.isfile(audio):
        raise Usage("the transcript has no spoken_words and the narration to transcribe is missing (%s)" % (audio or "no --audio"))
    script = find_transcribe_script(script)
    if not script:
        raise Usage("the transcript has no spoken_words and the speech-to-text script is missing "
                    "(.hub/c-audio/scripts/transcribe.sh); re-run the transcribe step so it saves spoken_words")
    os.makedirs(os.path.dirname(os.path.abspath(out_json)), exist_ok=True)
    proc = subprocess.run(["bash", script, audio, out_json], capture_output=True, text=True)
    if proc.returncode != 0:
        raise Usage("the transcript has no spoken_words and transcribing the narration failed (exit %d): %s"
                    % (proc.returncode, tail(proc.stderr or proc.stdout)))
    rows = word_rows(read_json(out_json, "the recognised words").get("words"))
    if not rows:
        raise Usage("transcribing the narration found no words")
    return rows


# ---- end card ---------------------------------------------------------------------------------------

def end_card_start(plan_path):
    """Start of the last gfx:cta row, or None when the plan is missing or has no such row."""
    if not os.path.isfile(plan_path):
        return None
    plan = read_json(plan_path, "the b-roll plan")
    rows = plan.get("rows") if isinstance(plan, dict) else plan
    if not isinstance(rows, list):
        return None
    starts = []
    for r in rows:
        if isinstance(r, dict) and r.get("asset") == "gfx:cta":
            try:
                starts.append(float(r["start"]))
            except (KeyError, TypeError, ValueError):
                raise Usage("the gfx:cta row of %s has no usable start" % plan_path)
    return starts[-1] if starts else None


def brand_accent(workdir):
    """Brief palette accent, else the brand file's, else the default. Same order as scripts/end-card.py."""
    brand = _brief(workdir).get("brand")
    brand = brand if isinstance(brand, dict) else {}
    pal = brand.get("palette") if isinstance(brand.get("palette"), dict) else {}
    found = hex_colour(pal.get("accent"))
    if found:
        return found
    slug = brand.get("slug")
    if isinstance(slug, str) and SLUG_RE.match(slug):
        f = os.path.join(SKILL_DIR, "brand-overrides", slug, "brand.json")
        if os.path.isfile(f):
            ov = read_json(f, "the brand file")
            opal = ov.get("palette") if isinstance(ov, dict) and isinstance(ov.get("palette"), dict) else {}
            found = hex_colour(opal.get("accent"))
            if found:
                return found
    return DEFAULT_ACCENT


# ---- build ------------------------------------------------------------------------------------------

def group_words(words):
    """Indexes of words, grouped into captions."""
    groups, cur, chars = [], [], 0
    for i, (tok, s, e) in enumerate(words):
        if cur:
            p = words[cur[-1]][0]
            if (len(cur) >= MAX_WORDS
                    or chars + 1 + len(tok) > MAX_CHARS
                    or SENTENCE_END.search(p)
                    or (len(cur) >= 4 and CLAUSE_END.search(p))
                    or s - words[cur[-1]][2] >= PAUSE_BREAK
                    or e - words[cur[0]][1] > MAX_SPAN):
                groups.append(cur)
                cur, chars = [], 0
        chars += len(tok) + (1 if cur else 0)
        cur.append(i)
    if cur:
        groups.append(cur)
    return groups


def split_lines(tokens):
    """Token lists for one or two lines of similar length."""
    if len(tokens) < 2 or sum(len(x) for x in tokens) + len(tokens) - 1 <= LINE_CHARS:
        return [tokens]
    best, best_k = None, 1
    for k in range(1, len(tokens)):
        worst = max(len(" ".join(tokens[:k])), len(" ".join(tokens[k:])))
        if best is None or worst < best:
            best, best_k = worst, k
    return [tokens[:best_k], tokens[best_k:]]


def build_events(words, cut, accent_bgr):
    """[(start_cs, end_cs, text)] with the active word in the accent colour."""
    if cut is not None:
        words = [w for w in words if w[1] < cut - MIN_EVENT]
    if not words:
        raise Usage("no spoken word starts before the end card (%s)" % ("none" if cut is None else fmt(cut)))
    t = []                                   # strictly increasing show times, never earlier than the word
    for tok, s, e in words:
        t.append(max(s, t[-1] + MIN_EVENT) if t else s)
    events = []
    groups = group_words(words)
    for gi, grp in enumerate(groups):
        toks = [words[i][0] for i in grp]
        nxt = t[groups[gi + 1][0]] if gi + 1 < len(groups) else None
        for pos, i in enumerate(grp):
            start = t[i]
            if pos + 1 < len(grp):
                end = t[grp[pos + 1]]
            else:
                end = max(words[i][2], start + MIN_LAST) + LINGER
                if nxt is not None:
                    end = min(end, nxt)
            if cut is not None:
                end = min(end, cut)
            if end - start < MIN_EVENT - 1e-9:
                continue
            lines, k = split_lines(toks), 0
            rendered = []
            for line in lines:
                parts = []
                for tok in line:
                    parts.append("{\\1c%s&}%s{\\r}" % (accent_bgr, tok) if k == pos else tok)
                    k += 1
                rendered.append(" ".join(parts))
            s_cs = int(round(start * 100))
            e_cs = max(int(round(end * 100)), s_cs + 1)
            events.append((s_cs, e_cs, "\\N".join(rendered)))
    return events


def ass_document(events):
    head = [
        "[Script Info]",
        "; Written by scripts/captions.py. Do not edit by hand: run `captions.py build` again.",
        "Title: p-longform captions",
        "ScriptType: v4.00+",
        "PlayResX: 1920",
        "PlayResY: 1080",
        "WrapStyle: 0",
        "ScaledBorderAndShadow: yes",
        "",
        "[V4+ Styles]",
        "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
        "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, "
        "MarginR, MarginV, Encoding",
        "Style: Caption,%s,%d,%s,%s,%s,%s,-1,0,0,0,100,100,0,0,3,%d,0,2,%d,%d,%d,1"
        % (FONT, FONT_SIZE, WHITE, WHITE, BOX_COLOUR, BOX_COLOUR, BOX_PAD, MARGIN_X, MARGIN_X, MARGIN_V),
        "",
        "[Events]",
        "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    body = ["Dialogue: 0,%s,%s,Caption,,0,0,0,,%s" % (cs_time(s), cs_time(e), txt) for s, e, txt in events]
    return "\n".join(head + body) + "\n"


def cmd_build(args):
    workdir = args.dir
    transcript = args.transcript or args.srt
    if not transcript:
        if not workdir:
            raise Usage("give --transcript (or --srt), or --dir")
        transcript = os.path.join(workdir, "prior", "transcripts.json")
    out = args.out or (os.path.join(workdir, "work", "captions.ass") if workdir else None)
    if not out:
        raise Usage("give --out, or --dir")
    cut = args.end_card_start
    if cut is None and workdir:
        cut = end_card_start(os.path.join(workdir, "prior", "broll_plan.json"))
        if cut is None:
            print("note: no gfx:cta row in prior/broll_plan.json; captions run to the last word")
    accent = hex_colour(args.accent) if args.accent else (brand_accent(workdir) if workdir else DEFAULT_ACCENT)
    if args.accent and not accent:
        raise Usage("--accent must look like #F97316")
    rows, spoken, kind = load_speech(transcript, force_srt=bool(args.srt and not args.transcript))
    added, note = 0, ""
    if kind != "srt":                                    # an SRT given by hand is captioned exactly as it is
        if spoken is None:
            audio = args.audio or (os.path.join(workdir, "prior", "composite_video.mp4") if workdir else None)
            raw = os.path.join(os.path.dirname(os.path.abspath(out)), "spoken-raw.json")
            spoken = recognise_narration(audio, raw, args.transcribe_script)
            note = ", the narration was transcribed (no spoken_words in the transcript)"
        rows, added = fill_alignment_holes(rows, spoken)
    words = to_words(rows)
    events = build_events(words, cut, ass_colour(accent))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(ass_document(events))
    print("built %d caption events for %d words (%d filled in from the recognised speech%s), last one ends %s, "
          "end card %s, accent %s -> %s" % (len(events), len(words), added, note, fmt(events[-1][1] / 100.0),
                                            "none" if cut is None else fmt(cut), accent, out))
    return 0


# ---- burn -------------------------------------------------------------------------------------------

def has_ass_filter(ffmpeg):
    try:
        proc = subprocess.run([ffmpeg, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return any(re.match(r"^\s*\S+\s+ass\s+V->V", ln) for ln in proc.stdout.splitlines())


def find_ffmpeg_with_ass():
    explicit = os.environ.get("CFW_FFMPEG")
    if explicit:
        if has_ass_filter(explicit):
            return explicit
        raise Usage("CFW_FFMPEG (%s) has no ass filter (libass)" % os.path.basename(explicit))
    tried = []
    for cand in (shutil.which("ffmpeg"), "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg", "/usr/local/opt/ffmpeg-full/bin/ffmpeg"):
        if cand and cand not in tried:
            tried.append(cand)
            if os.path.isfile(cand) and has_ass_filter(cand):
                return cand
    raise Usage("no ffmpeg with the ass filter (libass) was found; the burn needs ffmpeg-full "
                "(brew install ffmpeg-full) or CFW_FFMPEG set to a build that has it. Tried: %s"
                % (", ".join(tried) or "none"))


def fg_quote(text):
    return "'" + text.replace("'", "'\\''") + "'"


def cmd_burn(args):
    workdir = args.dir or "."
    src = os.path.join(SKILL_DIR, "fonts", FONT_FILE)
    if not os.path.isfile(src):
        raise Usage("the bundled caption font is missing (fonts/%s)" % FONT_FILE)
    ff = find_ffmpeg_with_ass()
    fonts = os.path.join(workdir, "work", "fonts")
    os.makedirs(fonts, exist_ok=True)
    shutil.copyfile(src, os.path.join(fonts, FONT_FILE))
    inp, ass, out = args.input, args.ass, args.out
    for label, p in (("video", inp), ("caption file", ass)):
        if not os.path.isfile(os.path.join(workdir, p)):
            raise Usage("the %s to burn is missing (%s)" % (label, p))
    os.makedirs(os.path.dirname(os.path.abspath(os.path.join(workdir, out))), exist_ok=True)
    vf = "ass=filename=%s:fontsdir=%s" % (fg_quote(ass), fg_quote("work/fonts"))
    cmd = [ff, "-y", "-nostdin", "-hide_banner", "-v", "error", "-i", inp, "-vf", vf, "-c:v", "libx264",
           "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "18", "-g", "25", "-c:a", "copy",
           "-movflags", "+faststart", out]
    proc = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True)
    if proc.returncode != 0:
        raise Usage("the caption burn failed (ffmpeg exit %d): %s" % (proc.returncode, tail(proc.stderr)))
    print("burned %s into %s with %s" % (ass, out, FONT))
    return 0


# ---- verify -----------------------------------------------------------------------------------------

def parse_ass_events(text):
    """([(start, end)] of events that show text, number of events whose end is not after their start)."""
    cols = ["Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"]
    in_events, events, bad = False, [], 0
    for line in text.replace("\r\n", "\n").split("\n"):
        s = line.strip()
        if s.startswith("["):
            in_events = s.lower() == "[events]"
            continue
        if not in_events:
            continue
        if s.lower().startswith("format:"):
            cols = [c.strip() for c in s.split(":", 1)[1].split(",")]
        elif s.startswith("Dialogue:"):
            parts = s.split(":", 1)[1].lstrip().split(",", len(cols) - 1)
            if len(parts) < len(cols) or "Start" not in cols or "End" not in cols or "Text" not in cols:
                continue
            a, b = parse_ts(parts[cols.index("Start")]), parse_ts(parts[cols.index("End")])
            shown = re.sub(r"\{[^}]*\}", "", parts[cols.index("Text")])
            shown = re.sub(r"\\[Nnh]", " ", shown).strip()
            if a is None or b is None or not shown:
                continue
            if b <= a:
                bad += 1
                continue
            events.append((a, b))
    return events, bad


def merge(spans, join=0.0):
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1] + join:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [(a, b) for a, b in out]


def clip(spans, lo, hi):
    return [(max(a, lo), min(b, hi)) for a, b in spans if min(b, hi) > max(a, lo)]


def subtract(spans, covers):
    """The parts of `spans` that no `covers` interval touches. Both are merged and sorted."""
    gaps = []
    for a, b in spans:
        cur = a
        for c, d in covers:
            if d <= cur:
                continue
            if c >= b:
                break
            if c > cur:
                gaps.append((cur, c))
            cur = max(cur, d)
            if cur >= b:
                break
        if cur < b:
            gaps.append((cur, b))
    return [(a, b) for a, b in gaps if b - a > 1e-6]


def measure(spans):
    return sum(b - a for a, b in spans)


def voiced_spans(audio, ffmpeg=None):
    """[(start, end)] of the time the narration audio is not silent (silencedetect)."""
    ffmpeg = ffmpeg or shutil.which("ffmpeg")
    if not ffmpeg:
        raise Usage("ffmpeg was not found, so the narration cannot be measured")
    if not audio or not os.path.isfile(audio):
        raise Usage("the narration audio to measure is missing (%s)" % (audio or "no --audio"))
    proc = subprocess.run([ffmpeg, "-hide_banner", "-nostdin", "-nostats", "-i", audio, "-vn", "-af",
                           "silencedetect=n=%ddB:d=%s" % (SILENCE_DB, SILENCE_MIN), "-f", "null", "-"],
                          capture_output=True, text=True)
    log = proc.stderr
    if proc.returncode != 0:
        raise Usage("ffmpeg could not read the narration audio (exit %d): %s" % (proc.returncode, tail(log)))
    if not re.search(r"Stream #\S+.*Audio:", log):
        raise Usage("the narration file has no audio stream")
    m = re.search(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", log)
    if not m:
        raise Usage("ffmpeg did not report the narration length")
    duration = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    silences, start = [], None
    for ln in log.splitlines():
        a = re.search(r"silence_start: (-?[\d.]+)", ln)
        b = re.search(r"silence_end: (-?[\d.]+)", ln)
        if a:
            start = max(float(a.group(1)), 0.0)
        elif b and start is not None:
            silences.append((start, float(b.group(1))))
            start = None
    if start is not None:
        silences.append((start, duration))
    voiced, at = [], 0.0
    for a, b in silences:
        if a > at:
            voiced.append((at, a))
        at = max(at, b)
    if at < duration:
        voiced.append((at, duration))
    return [(a, b) for a, b in voiced if b - a >= MIN_VOICED]


def check_coverage(rows, events, cut, max_gap=MAX_GAP, min_cover=MIN_COVER):
    """Return (summary, problems): problems is empty when the captions are good enough. `rows` are the
    voiced stretches as (start, end, _)."""
    limit = float("inf") if cut is None else cut
    speech = clip(merge([(s, e) for s, e, _ in rows], 0.0), 0.0, limit)
    total = measure(speech)
    if total <= 0:
        raise Usage("the narration has no speech before the end card")
    caps = merge(events)
    gaps = subtract(speech, caps)
    cover = 1.0 - measure(gaps) / total
    # A stretch is the time from the first uncaptioned speech to the last one with no caption on screen in
    # between: sentences with short pauses between them are one stretch, not several short ones.
    stretches = []
    for g in gaps:
        if stretches and not any(c < g[0] and d > stretches[-1][1] for c, d in caps):
            stretches[-1] = (stretches[-1][0], g[1])
        else:
            stretches.append(g)
    worst = max(stretches, key=lambda g: g[1] - g[0]) if stretches else None
    worst_len = worst[1] - worst[0] if worst else 0.0
    over = measure(clip(caps, limit, float("inf")))
    problems = []
    long_gaps = [g for g in stretches if g[1] - g[0] > max_gap + 1e-6]
    if long_gaps:
        first = ", ".join("%s-%s" % (fmt(a), fmt(b)) for a, b in long_gaps[:3])
        problems.append("no caption for %.1f s of speech at %s (limit %.1f s); stretches over the limit: %d, first: %s"
                        % (worst_len, fmt(worst[0]), max_gap, len(long_gaps), first))
    if cover < min_cover - 1e-9:
        problems.append("captions cover %.1f%% of the speech (need %.0f%%)" % (cover * 100, min_cover * 100))
    if cut is not None and over > CARD_OVERLAP:
        problems.append("a caption is on screen over the end card (%.1f s after %s)" % (over, fmt(cut)))
    summary = "cover %.1f%% of %.1f s voiced speech%s, worst gap %.2f s%s, %d events" % (
        cover * 100, total, "" if cut is None else " before " + fmt(cut), worst_len,
        " at " + fmt(worst[0]) if worst else "", len(events))
    return summary, problems


def cmd_verify(args):
    workdir = args.dir
    if workdir:
        choice, source = captions_state(workdir)
        if choice == "off":
            asked = intent_asks_for_captions(workdir)
            if asked:
                raise Fail("the brief asks for captions (\"%s\") but the captions choice is off (%s); "
                           "set captions on, or take the request out of the brief" % (asked, source))
            print("PASS captions: off (%s), nothing to verify" % source)
            return 0
    ass = args.ass or (os.path.join(workdir, "work", "captions.ass") if workdir else None)
    audio = args.audio or (os.path.join(workdir, "prior", "composite_video.mp4") if workdir else None)
    if not ass or not audio:
        raise Usage("give --ass and --audio, or --dir")
    cut = args.end_card_start
    if cut is None and workdir:
        cut = end_card_start(os.path.join(workdir, "prior", "broll_plan.json"))
    if not os.path.isfile(ass):
        raise Fail("captions are on but the caption file was not built (%s); run captions.py build" % ass)
    try:
        with open(ass, encoding="utf-8") as fh:
            events, bad = parse_ass_events(fh.read())
    except OSError as exc:
        raise Usage("cannot read the caption file (%s): %s" % (ass, exc.strerror or exc))
    rows = [(a, b, "") for a, b in voiced_spans(audio)]
    summary, problems = check_coverage(rows, events, cut, args.max_gap, args.min_cover)
    if bad:
        summary += ", %d events ignored (end not after start)" % bad
    if problems:
        raise Fail("; ".join(problems) + " [" + summary + "]")
    print("PASS captions: " + summary)
    return 0


def cmd_choice(args):
    print(captions_choice(args.dir or "."))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="captions.py", description="Build, burn and verify the p-longform captions.")
    sub = ap.add_subparsers(dest="mode", required=True)
    for name in ("build", "verify", "choice", "burn"):
        p = sub.add_parser(name)
        p.add_argument("--dir", help="step workdir (brief.json, inputs/, prior/, work/, saves/)")
        if name == "choice":
            continue
        if name == "burn":
            p.add_argument("--in", dest="input", default="work/loudnorm.mp4")
            p.add_argument("--ass", default="work/captions.ass")
            p.add_argument("--out", default="saves/mastered_video.mp4")
            continue
        p.add_argument("--end-card-start", type=float, help="seconds; captions stop here")
        p.add_argument("--audio", help="the narration: prior/composite_video.mp4")
        if name == "build":
            p.add_argument("--transcript", help="prior/transcripts.json, or an .srt file")
            p.add_argument("--srt", help="an SRT file")
            p.add_argument("--out", help="caption file to write (default work/captions.ass)")
            p.add_argument("--accent", help="active-word colour, #RRGGBB")
            p.add_argument("--transcribe-script", help="speech-to-text script (default .hub/c-audio/scripts/transcribe.sh)")
        else:
            p.add_argument("--ass", help="caption file to check (default work/captions.ass)")
            p.add_argument("--max-gap", type=float, default=MAX_GAP)
            p.add_argument("--min-cover", type=float, default=MIN_COVER)
    args = ap.parse_args(argv)
    try:
        return {"build": cmd_build, "verify": cmd_verify, "choice": cmd_choice, "burn": cmd_burn}[args.mode](args)
    except Fail as exc:
        print("FAIL captions: %s" % exc)
        return 1
    except Usage as exc:
        print("ERROR captions: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
