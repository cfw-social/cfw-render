#!/usr/bin/env python3
"""Tests for the p-longform caption tools (B51): scripts/captions.py, scripts/caption-safe.py and
checks/master_has_speech.sh.

Run on their own, from anywhere:  python3 -I harness/skills/p-longform/tests/test_captions.py

Hermetic and small. Every transcript, caption file and narration here is made in the test from invented
words ("w001 w002 ..."): nothing of a real talk is stored. The parts that need ffmpeg (measuring the
narration, the shell check, the still fitter, the burn) skip themselves when it is not installed. Nothing
here touches a render, a worker or a network.
"""
import importlib.util
import json
import math
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import wave

sys.dont_write_bytecode = True          # no __pycache__ next to the recipe files, which are hashed into the bundle
HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
CAPTIONS = os.path.join(SKILL, "scripts", "captions.py")
SAFE = os.path.join(SKILL, "scripts", "caption-safe.py")
CHECK = os.path.join(SKILL, "checks", "master_has_speech.sh")
BUILD_SEGMENTS = os.path.join(os.path.dirname(SKILL), "c-ffmpeg", "scripts", "build-segments.py")
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))

spec = importlib.util.spec_from_file_location("captions_under_test", CAPTIONS)
cap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cap)

try:
    HAVE_ASS = HAVE_FFMPEG and cap.find_ffmpeg_with_ass() is not None
except cap.Usage:
    HAVE_ASS = False


def run(*argv, env=None):
    proc = subprocess.run([sys.executable, "-I", *argv], capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def write(path, text):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def event_lines(ass_text):
    return [ln for ln in ass_text.split("\n") if ln.startswith("Dialogue:")]


def line_times(line):
    parts = line.split(":", 1)[1].lstrip().split(",", 9)
    return cap.parse_ts(parts[1]), cap.parse_ts(parts[2]), parts[9]


def drop_events_between(ass_text, windows):
    """The same ASS without the events that touch any (start, end) window, in seconds."""
    keep = []
    for ln in ass_text.split("\n"):
        if ln.startswith("Dialogue:"):
            s, e, _ = line_times(ln)
            if any(s < b and e > a for a, b in windows):
                continue
        keep.append(ln)
    return "\n".join(keep)


# ---- a made-up talk -----------------------------------------------------------------------------------

SENTENCES, PER_SENTENCE, STEP, SAY = 25, 9, 0.3, 0.26
PERIOD = PER_SENTENCE * STEP + 1.0                    # nine words, then a 1 s pause
START = 0.5
CARD = START + SENTENCES * PERIOD + 1.0               # the end card starts a second after the last word
DURATION = CARD + 3.0


def talk():
    """Every word of the made-up talk: [{w, start, end}], sentences of nine words, 1 s pauses."""
    words = []
    for k in range(SENTENCES):
        for i in range(PER_SENTENCE):
            start = START + k * PERIOD + i * STEP
            words.append({"w": "w%03d%s" % (len(words), "." if i == PER_SENTENCE - 1 else ""),
                          "start": round(start, 3), "end": round(start + SAY, 3)})
    return words


def voiced_of(words):
    """The sentences as voiced stretches: the audio is silent in the pauses between them."""
    return [(words[k * PER_SENTENCE]["start"], words[(k + 1) * PER_SENTENCE - 1]["end"]) for k in range(SENTENCES)]


def without(words, a, b):
    return [w for w in words if not (a <= w["start"] < b)]


def write_wav(path, voiced, duration, rate=8000):
    """A mono 16-bit tone where voiced, silence elsewhere, in 0.1 s steps (30 whole cycles of 300 Hz each)."""
    tone = b"".join(struct.pack("<h", int(0.3 * 32767 * math.sin(2 * math.pi * 300 * i / rate))) for i in range(rate // 10))
    quiet = b"\x00\x00" * (rate // 10)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        for tick in range(int(round(duration * 10))):
            mid = tick / 10.0 + 0.05
            w.writeframes(tone if any(a <= mid < b for a, b in voiced) else quiet)


def to_mp4(wav, out, volume=1.0, seconds=None):
    """A small video that carries the narration."""
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    seconds = seconds or DURATION
    subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "color=c=black:s=160x90:r=25:d=%.2f" % seconds, "-i", wav, "-af", "volume=%s" % volume,
                    "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", out],
                   check=True, capture_output=True)


def make_workdir(root, aligned=None, spoken=None, choice=None, intent=None, options=None, accent=None, cta=CARD):
    """A step workdir shaped like post_process gets it. choice None = no captions input at all."""
    words = talk()
    transcript = {"duration": DURATION, "avatar_mode": "supplied", "words": aligned if aligned is not None else words}
    if spoken is not False:
        transcript["spoken_words"] = spoken if spoken is not None else words
    write(os.path.join(root, "prior", "transcripts.json"), json.dumps(transcript))
    rows = [{"start": 0, "end": cta, "layout": "AVATAR_FULL", "asset": None},
            {"start": cta, "end": cta + 4, "layout": "FULLSCREEN_BROLL", "asset": "gfx:cta", "zoom": "none"}]
    write(os.path.join(root, "prior", "broll_plan.json"), json.dumps({"duration": cta + 4, "rows": rows}))
    brand = {"slug": "test-brand", "name": "Test Brand"}
    if accent:
        brand["palette"] = {"accent": accent}
    brief = {"brand": brand, "options": options or {}}
    if intent is not None:
        brief["intent"] = intent
    write(os.path.join(root, "brief.json"), json.dumps(brief))
    if choice is not None:
        write(os.path.join(root, "inputs", "captions", "captions.md"), choice)
    return root


def add_narration(root, voiced=None, volume=1.0):
    """prior/composite_video.mp4 (the narration) and saves/mastered_video.mp4 for the shell check."""
    wav = os.path.join(root, "work", "narration.wav")
    write_wav(wav, voiced if voiced is not None else voiced_of(talk()), DURATION)
    to_mp4(wav, os.path.join(root, "prior", "composite_video.mp4"))
    to_mp4(wav, os.path.join(root, "saves", "mastered_video.mp4"), volume=volume)


def stub_transcriber(root, words):
    """A speech-to-text stand-in: writes `words` where transcribe.sh would."""
    data = os.path.join(root, "heard.json")
    write(data, json.dumps({"duration": DURATION, "words": words}))
    script = os.path.join(root, "stub-transcribe.sh")
    write(script, '#!/usr/bin/env bash\nmkdir -p "$(dirname "$2")"\ncp "%s" "$2"\n' % data)
    os.chmod(script, os.stat(script).st_mode | stat.S_IEXEC)
    return script


def foreign_ass(spans, step=2.5):
    """A caption file in another style (one style, \\pos on every line), like the one an engine wrote by hand."""
    lines = ["[Script Info]", "ScriptType: v4.00+", "PlayResX: 1920", "PlayResY: 1080", "[V4+ Styles]",
             "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, "
             "Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, "
             "MarginR, MarginV, Encoding",
             "Style: Default,Inter,44,&H00FFFFFF,&H00FFFFFF,&H00101724,&H90101724,-1,0,0,0,100,100,0,0,1,3,1,2,450,450,65,1",
             "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
    for a, b in spans:
        t = a
        while t < b - 1e-6:
            e = min(t + step, b)
            lines.append("Dialogue: 0,%s,%s,Default,,0,0,0,,{\\an2\\pos(960,1010)}hello, world" % (cap.cs_time(int(t * 100)), cap.cs_time(int(e * 100))))
            t = e
    return "\n".join(lines) + "\n"


# ---- tests --------------------------------------------------------------------------------------------

class ChoiceTests(unittest.TestCase):
    def choice(self, **kw):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, **kw)
            code, text = run(CAPTIONS, "choice", "--dir", tmp)
            self.assertEqual(code, 0, text)
            return text.strip()

    def test_on_when_there_is_no_input(self):                     # B2: the MGG order has no captions input
        self.assertEqual(self.choice(), "on")
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run(CAPTIONS, "choice", "--dir", tmp)[1].strip(), "on")      # not even a brief

    def test_only_an_explicit_off_is_off(self):
        for answer in ("off", "OFF\n", "no", "false", "0", "none", "No captions please"):
            self.assertEqual(self.choice(choice=answer), "off", answer)
        for answer in ("on", "yes please", "true", "1", "maybe", "", "  "):
            self.assertEqual(self.choice(choice=answer), "on", repr(answer))

    def test_json_choice(self):
        for value, expect in (("on", "on"), ("off", "off")):
            with tempfile.TemporaryDirectory() as tmp:
                make_workdir(tmp)
                write(os.path.join(tmp, "inputs", "captions", "captions.json"), json.dumps({"choice": value}))
                self.assertEqual(run(CAPTIONS, "choice", "--dir", tmp)[1].strip(), expect)

    def test_the_brief_option_decides_when_there_is_no_input(self):
        self.assertEqual(self.choice(options={"captions": False}), "off")
        self.assertEqual(self.choice(options={"captions": "off"}), "off")
        self.assertEqual(self.choice(options={"captions": True}), "on")
        self.assertEqual(self.choice(options={"captions": False}, choice="on"), "on")      # the typed answer wins


class BuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        make_workdir(cls.tmp, choice="on")
        code, text = run(CAPTIONS, "build", "--dir", cls.tmp)
        assert code == 0, text
        cls.path = os.path.join(cls.tmp, "work", "captions.ass")
        cls.text = read(cls.path)
        cls.lines = event_lines(cls.text)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_same_input_same_bytes(self):
        again = os.path.join(self.tmp, "again.ass")
        env = dict(os.environ, PYTHONHASHSEED="12345")
        code, text = run(CAPTIONS, "build", "--dir", self.tmp, "--out", again, env=env)
        self.assertEqual(code, 0, text)
        with open(self.path, "rb") as a, open(again, "rb") as b:
            self.assertEqual(a.read(), b.read())

    def test_every_word_before_the_end_card_is_captioned_in_order(self):
        active = [re.search(r"\{\\1c[^}]*\}(.*?)\{\\r\}", ln.split(",,", 1)[1]).group(1) for ln in self.lines]
        self.assertEqual(active, [w["w"] for w in talk()])

    def test_one_fixed_style(self):
        self.assertEqual(len(re.findall(r"^Style:", self.text, re.M)), 1)
        style = re.search(r"^Style: (.*)$", self.text, re.M).group(1).split(",")
        self.assertEqual(style[1:3], ["Inter", "56"])             # font and size from steps/07
        self.assertEqual(style[-4:-1], ["420", "420", "70"])      # text inside x 420-1500
        self.assertEqual(style[15], "3")                          # BorderStyle 3: a backing box
        self.assertIn("PlayResX: 1920", self.text)
        self.assertIn("PlayResY: 1080", self.text)

    def test_captions_are_short_and_in_order(self):
        last_end = 0.0
        for ln in self.lines:
            s, e, text = line_times(ln)
            self.assertGreater(e, s)
            self.assertGreaterEqual(s, last_end - 0.011)          # no event starts before the last one ended
            last_end = e
            plain = re.sub(r"\{[^}]*\}", "", text)
            self.assertLessEqual(len(plain.replace("\\N", " ").split()), cap.MAX_WORDS)
            self.assertLessEqual(plain.count("\\N"), 1)
            self.assertNotIn("\\pos", text)                       # no per-beat position: the layout is never read

    def test_accent_follows_the_brand(self):
        self.assertIn("&H001673F9&", self.text)                   # #F97316 as ASS BGR, the default accent
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, accent="#00AAFF")
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            blue = read(os.path.join(tmp, "work", "captions.ass"))
        self.assertIn("&H00FFAA00&", blue)
        self.assertNotIn("&H001673F9&", blue)

    def test_text_cannot_inject_ass_tags(self):
        events = cap.build_events(cap.to_words([(0.0, 2.0, r"a{\pos(1,1)}b \N c}")]), None, "&H00FFFFFF")
        joined = "".join(t for _, _, t in events)
        self.assertNotIn("\\pos", joined)

    def test_words_with_bad_times_never_make_a_dead_event(self):
        rows = [(1.0, 0.5, "a"), (1.0, 1.0, "b"), (1.0, 1.2, "c"), (2.0, 2.2, "d")]
        events = cap.build_events(cap.to_words([(s, max(s, e), t) for s, e, t in rows]), None, "&H00FFFFFF")
        self.assertEqual(len(events), 4)
        self.assertTrue(all(e > s for s, e, _ in events))


class EndCardTests(unittest.TestCase):
    def test_nothing_starts_at_or_after_the_card_and_the_running_caption_is_clipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, cta=40.0)
            code, text = run(CAPTIONS, "build", "--dir", tmp)
            self.assertEqual(code, 0, text)
            times = [line_times(ln) for ln in event_lines(read(os.path.join(tmp, "work", "captions.ass")))]
            self.assertTrue(times and all(s < 40.0 for s, _, _ in times))
            self.assertTrue(all(e <= 40.011 for _, e, _ in times))
            self.assertAlmostEqual(times[-1][1], 40.0, delta=0.011)      # the one on screen ends at the card

    def test_speech_over_the_card_is_not_a_gap_but_a_caption_over_it_fails(self):
        voiced = voiced_of(talk())
        rows = [(a, b, "") for a, b in voiced]
        good = cap.parse_ass_events(foreign_ass([(a, b + 0.5) for a, b in voiced if b < CARD]))[0]
        self.assertEqual(cap.check_coverage(rows, good, CARD)[1], [])
        over = good + [(CARD + 0.5, CARD + 3.0)]
        problems = cap.check_coverage(rows, over, CARD)[1]
        self.assertTrue(any("over the end card" in p for p in problems), problems)


class AlignmentHoleTests(unittest.TestCase):
    """B1: the aligned `words` can have a hole where the speaker said something that is not in the script."""
    HOLE = (30.0, 52.0)

    def holed(self):
        words = talk()
        return without(words, *self.HOLE), words

    def covered(self, ass_text, a, b):
        """The share of the voiced narration between a and b that has a caption."""
        events, _ = cap.parse_ass_events(ass_text)
        speech = cap.clip(voiced_of(talk()), a, b)
        return 1.0 - cap.measure(cap.subtract(speech, cap.merge(events))) / cap.measure(speech)

    def test_build_covers_the_hole_from_the_recognised_words(self):
        aligned, heard = self.holed()
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=heard)
            code, text = run(CAPTIONS, "build", "--dir", tmp)
            self.assertEqual(code, 0, text)
            ass = read(os.path.join(tmp, "work", "captions.ass"))
            self.assertIn("filled in from the recognised speech", text)
            self.assertGreater(self.covered(ass, *self.HOLE), 0.99)
            active = [re.search(r"\{\\1c[^}]*\}(.*?)\{\\r\}", ln.split(",,", 1)[1]).group(1) for ln in event_lines(ass)]
            self.assertEqual(active, [w["w"] for w in heard])                  # every heard word, once, in order

    def test_without_the_recognised_words_the_hole_stays_and_is_unfilled(self):
        aligned, heard = self.holed()
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=aligned)                  # nothing heard in the hole either
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            self.assertLess(self.covered(read(os.path.join(tmp, "work", "captions.ass")), *self.HOLE), 0.05)

    def test_a_long_unspoken_word_does_not_hide_a_hole(self):
        """Step 03 spreads a script word nobody said over the gap; it must not count as speech for 20 s."""
        aligned, heard = self.holed()
        aligned = sorted(aligned + [{"w": "ghost", "start": 31.0, "end": 51.0}], key=lambda w: w["start"])
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=heard)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            self.assertGreater(self.covered(read(os.path.join(tmp, "work", "captions.ass")), *self.HOLE), 0.99)

    def test_a_restored_transcript_without_spoken_words_is_transcribed(self):
        aligned, heard = self.holed()
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=False)
            stub = stub_transcriber(tmp, heard)
            write(os.path.join(tmp, "prior", "composite_video.mp4"), "narration stand-in")
            code, text = run(CAPTIONS, "build", "--dir", tmp, "--transcribe-script", stub)
            self.assertEqual(code, 0, text)
            self.assertIn("the narration was transcribed", text)
            self.assertGreater(self.covered(read(os.path.join(tmp, "work", "captions.ass")), *self.HOLE), 0.99)

    def test_it_stops_and_says_why_when_it_cannot_transcribe(self):
        aligned, heard = self.holed()
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=False)
            stub = stub_transcriber(tmp, heard)
            code, text = run(CAPTIONS, "build", "--dir", tmp, "--transcribe-script", stub)         # no narration file
            self.assertEqual(code, 2, text)
            self.assertIn("narration to transcribe is missing", text)
            write(os.path.join(tmp, "prior", "composite_video.mp4"), "narration stand-in")
            code, text = run(CAPTIONS, "build", "--dir", tmp, "--transcribe-script", os.path.join(tmp, "nope.sh"))
            self.assertEqual(code, 2, text)
            self.assertIn("speech-to-text script is missing", text)
            bad = os.path.join(tmp, "bad.sh")
            write(bad, "#!/usr/bin/env bash\necho 'no model' >&2\nexit 2\n")
            code, text = run(CAPTIONS, "build", "--dir", tmp, "--transcribe-script", bad)
            self.assertEqual(code, 2, text)
            self.assertIn("transcribing the narration failed", text)
            self.assertIn("no model", text)
            self.assertFalse(os.path.exists(os.path.join(tmp, "work", "captions.ass")))        # nothing half-written

    def heard_copy(self, words, offsets):
        """What the recogniser heard: the same words, off by a little, spelled without case or the full stop."""
        return [{"w": w["w"].rstrip(".").upper(), "start": round(max(w["start"] + offsets[i % len(offsets)], 0.0), 3),
                 "end": round(max(w["end"] + offsets[i % len(offsets)], 0.01), 3)} for i, w in enumerate(words)]

    def active_tokens(self, ass):
        return [re.search(r"\{\\1c[^}]*\}(.*?)\{\\r\}", ln.split(",,", 1)[1]).group(1) for ln in event_lines(ass)]

    def test_a_word_heard_a_little_off_its_aligned_copy_is_captioned_once(self):       # B3
        words = talk()
        for offsets in ([0.2], [-0.2], [0.25, -0.25, 0.1, 0.0, -0.15, 0.3]):
            with tempfile.TemporaryDirectory() as tmp:
                make_workdir(tmp, aligned=words, spoken=self.heard_copy(words, offsets))
                code, text = run(CAPTIONS, "build", "--dir", tmp)
                self.assertEqual(code, 0, text)
                self.assertIn("(0 filled in from the recognised speech", text)
                tokens = self.active_tokens(read(os.path.join(tmp, "work", "captions.ass")))
                self.assertEqual(tokens, [w["w"] for w in words], offsets)
                for a, b in zip(tokens, tokens[1:]):
                    self.assertNotEqual(cap.norm_word(a), cap.norm_word(b))

    def test_a_real_hole_is_filled_without_doubling_the_words_around_it(self):         # B3 and B1 together
        aligned, heard = self.holed()
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=self.heard_copy(heard, [0.2, -0.2, 0.1]))
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            ass = read(os.path.join(tmp, "work", "captions.ass"))
            self.assertGreater(self.covered(ass, *self.HOLE), 0.95)                  # the heard times are off by up to 0.2 s
            tokens = self.active_tokens(ass)
            self.assertEqual(len(tokens), len(heard))                                # every word once
            for a, b in zip(tokens, tokens[1:]):
                self.assertNotEqual(cap.norm_word(a), cap.norm_word(b))

    def test_the_hole_rules(self):
        aligned = [(0.0, 0.3, "alpha"), (10.0, 10.3, "omega")]                       # a 9.7 s gap, and one under 1.2 s
        more = aligned + [(10.9, 11.2, "tail")]
        def added(spoken, rows=aligned):
            out, n = cap.fill_alignment_holes(rows, spoken)
            return [r[2] for r in out if r not in rows], n
        self.assertEqual(added([(3.0, 3.3, "middle")])[0], ["middle"])               # inside the hole
        self.assertEqual(added([(0.35, 0.6, "close")])[0], [])                       # under 0.15 s from the gap's edge
        self.assertEqual(added([(0.5, 0.8, "edge")])[0], ["edge"])                   # far enough from it
        self.assertEqual(added([(9.75, 9.95, "late")])[0], [])                       # under 0.15 s from the next word
        self.assertEqual(added([(0.5, 0.8, "Alpha,")])[0], [])                       # spells an aligned word 0.5 s away
        self.assertEqual(added([(5.0, 5.3, "ALPHA")])[0], ["ALPHA"])                 # the same spelling far away is a new word
        self.assertEqual(added([(10.4, 10.8, "gap")], more)[0], [])                  # a 0.6 s gap is not a hole
        self.assertEqual(added([(11.5, 11.8, "after")], more)[0], ["after"])         # after the last aligned word
        self.assertEqual(added([(5.0, 5.3, "")])[0], [""])                           # a blank word does not match anything

    def test_an_srt_given_by_hand_is_captioned_as_it_is(self):
        with tempfile.TemporaryDirectory() as tmp:
            srt = os.path.join(tmp, "talk.srt")
            write(srt, "1\n00:00:00,000 --> 00:00:04,000\n one two three four five six seven eight\n\n"
                       "2\n00:00:04,000 --> 00:00:06,000\n nine ten\n")
            out = os.path.join(tmp, "o.ass")
            code, text = run(CAPTIONS, "build", "--srt", srt, "--out", out)
            self.assertEqual(code, 0, text)
            self.assertEqual(len(event_lines(read(out))), 10)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
class VoicedAudioTests(unittest.TestCase):
    def test_voiced_spans_follow_the_audio(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "a.wav")
            truth = [(1.0, 4.0), (6.0, 7.5), (9.0, 12.0)]
            write_wav(wav, truth, 14.0)
            got = cap.voiced_spans(wav)
            self.assertEqual(len(got), 3, got)
            for (a, b), (c, d) in zip(got, truth):
                self.assertAlmostEqual(a, c, delta=0.25)
                self.assertAlmostEqual(b, d, delta=0.25)

    def test_a_pause_under_half_a_second_is_still_speech(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "a.wav")
            write_wav(wav, [(1.0, 3.0), (3.3, 5.0)], 6.0)
            self.assertEqual(len(cap.voiced_spans(wav)), 1)

    def test_a_missing_or_silent_file_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(cap.Usage):
                cap.voiced_spans(os.path.join(tmp, "missing.wav"))
            silent = os.path.join(tmp, "s.wav")
            write_wav(silent, [], 5.0)
            self.assertEqual(cap.voiced_spans(silent), [])
            with self.assertRaises(cap.Usage):
                cap.check_coverage([], [], None)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
class VerifyTests(unittest.TestCase):
    def verify(self, tmp, voiced=None, *extra):
        wav = os.path.join(tmp, "narration.wav")
        write_wav(wav, voiced if voiced is not None else voiced_of(talk()), DURATION)
        return run(CAPTIONS, "verify", "--ass", os.path.join(tmp, "x.ass"), "--audio", wav, "--end-card-start", str(CARD), *extra)

    def test_captions_from_the_script_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            shutil.copy(os.path.join(tmp, "work", "captions.ass"), os.path.join(tmp, "x.ass"))
            code, text = self.verify(tmp)
            self.assertEqual(code, 0, text)
            self.assertRegex(text, r"PASS captions: cover (99|100)\.\d% of [\d.]+ s voiced speech before 1:\d\d\.\d, worst gap")

    def test_a_foreign_caption_file_that_covers_the_speech_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "x.ass"), foreign_ass([(a - 0.1, b + 0.1) for a, b in voiced_of(talk())]))
            code, text = self.verify(tmp)
            self.assertEqual(code, 0, text)

    def test_the_b1_case_a_hole_in_the_words_fails_even_though_the_words_agree_with_the_captions(self):
        """The captions match the transcript word for word, and 22 s of voiced narration has no caption."""
        aligned = without(talk(), 30.0, 52.0)
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp, aligned=aligned, spoken=aligned)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            shutil.copy(os.path.join(tmp, "work", "captions.ass"), os.path.join(tmp, "x.ass"))
            code, text = self.verify(tmp)
            self.assertEqual(code, 1, text)
            self.assertTrue(text.startswith("FAIL captions: no caption for "), text)
            self.assertRegex(text, r"no caption for (1[0-9]|2[0-9])\.\d s of speech at 0:3\d\.\d")

    def test_gappy_captions_fail_with_a_clear_reason(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            write(os.path.join(tmp, "x.ass"), drop_events_between(read(os.path.join(tmp, "work", "captions.ass")),
                                                                  [(20.0, 33.0), (60.0, 80.0)]))
            code, text = self.verify(tmp)
            self.assertEqual(code, 1, text)
            self.assertEqual(text.count("\n"), 1)                     # one line of output
            self.assertTrue(text.startswith("FAIL captions: no caption for "), text)
            self.assertRegex(text, r"no caption for (19|20)\.\d s of speech at 1:0\d\.\d")     # the 20 s hole, worst first
            self.assertRegex(text, r"first: 0:(19|2\d)\.\d-0:3\d\.\d, 1:0\d\.\d-1:\d\d\.\d")   # both holes are named
            self.assertRegex(text, r"captions cover [5-9]\d\.\d% of the speech \(need 97%\)")

    def test_no_captions_at_all_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "x.ass"), foreign_ass([]))
            code, text = self.verify(tmp)
            self.assertEqual(code, 1, text)

    def test_captions_over_the_end_card_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "x.ass"), foreign_ass([(a - 0.1, b + 0.1) for a, b in voiced_of(talk())] + [(CARD + 0.5, CARD + 3.0)]))
            code, text = self.verify(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("over the end card", text)

    def test_the_narration_is_measured_not_the_transcript(self):
        """A talk with only the first half voiced needs captions only for that half."""
        half = voiced_of(talk())[:SENTENCES // 2]
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "x.ass"), foreign_ass([(a - 0.1, b + 0.1) for a, b in half]))
            self.assertEqual(self.verify(tmp, voiced=half)[0], 0)

    def test_unreadable_input_is_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            write(os.path.join(tmp, "x.ass"), foreign_ass([(1, 4)]))
            code, text = run(CAPTIONS, "verify", "--ass", os.path.join(tmp, "x.ass"), "--audio", os.path.join(tmp, "none.wav"))
            self.assertEqual(code, 2, text)

    def test_limits(self):
        """A gap passes while it is at most 3 s and the holes are under 3 % of the speech."""
        rows = [(0.0, 100.0, "x")]

        def verdict(*holes):
            cover, at = [], 0.0
            for a, b in holes:
                cover.append((at, a)); at = b
            cover.append((at, 100.0))
            return cap.check_coverage(rows, cover, None)[1]
        self.assertEqual(verdict((40.0, 42.5)), [])                                       # 2.5 s hole, 97.5 % covered
        self.assertTrue(any("no caption for 3.5 s" in p for p in verdict((40.0, 43.5))))  # over 3.0 s
        many = verdict((10.0, 11.5), (30.0, 31.5), (50.0, 51.5))                          # 4.5 % uncovered in small holes
        self.assertEqual(len(many), 1)
        self.assertIn("95.5%", many[0])

    def test_a_pause_in_the_speech_is_not_a_gap(self):
        rows = [(0.0, 10.0, ""), (20.0, 30.0, "")]                                        # 10 s of silence between
        self.assertEqual(cap.check_coverage(rows, [(0.0, 10.0), (20.0, 30.0)], None)[1], [])


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
class CheckScriptTests(unittest.TestCase):
    def check(self, tmp):
        proc = subprocess.run(["bash", CHECK, tmp], capture_output=True, text=True)
        return proc.returncode, proc.stdout + proc.stderr

    def workdir(self, tmp, volume=1.0, voiced=None, **kw):
        make_workdir(tmp, **kw)
        add_narration(tmp, voiced=voiced, volume=volume)
        return tmp

    def test_passes_with_good_captions(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp, choice="on")
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            code, text = self.check(tmp)
            self.assertEqual(code, 0, text)
            self.assertIn("PASS captions", text)

    def test_fails_when_the_narration_has_a_stretch_the_captions_miss(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp, choice="on")
            run(CAPTIONS, "build", "--dir", tmp)
            path = os.path.join(tmp, "work", "captions.ass")
            write(path, drop_events_between(read(path), [(30.0, 52.0)]))
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("no caption for", text)

    def test_the_real_failure_aligned_words_with_a_hole_over_voiced_audio_fail(self):
        aligned = without(talk(), 30.0, 52.0)
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp, aligned=aligned, spoken=aligned, choice="on")
            run(CAPTIONS, "build", "--dir", tmp)
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("no caption for", text)

    def test_no_captions_input_means_captions_are_required(self):         # B2
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp)                                               # no inputs/captions at all
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("was not built", text)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            self.assertEqual(self.check(tmp)[0], 0)

    def test_off_with_an_intent_that_asks_for_captions_fails(self):        # B2
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp, choice="off", intent="Make a 10 minute video with on-screen cards and captions")
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("the brief asks for captions", text)

    def test_off_passes_when_the_brief_does_not_ask(self):
        for intent in (None, "A calm 10 minute explainer", "Explainer, no captions please", "Cards without captions"):
            with tempfile.TemporaryDirectory() as tmp:
                self.workdir(tmp, choice="off", intent=intent)
                code, text = self.check(tmp)
                self.assertEqual(code, 0, "%r: %s" % (intent, text))
                self.assertIn("off", text)

    def test_a_silent_mix_fails_before_the_captions_are_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.workdir(tmp, volume=0.0005, choice="off")
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("does not carry speech", text)

    def test_no_video_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp)
            code, text = self.check(tmp)
            self.assertEqual(code, 1, text)
            self.assertIn("was not saved", text)


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    assert head[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    return struct.unpack(">II", head[16:24])


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
class CaptionSafeTests(unittest.TestCase):
    ROWS = [
        {"start": 0, "end": 2, "layout": "AVATAR_FULL", "asset": None, "zoom": "none"},
        {"start": 2, "end": 4, "layout": "FULLSCREEN_BROLL", "asset": "broll/diagram.png", "zoom": "slow-in"},
        {"start": 4, "end": 6, "layout": "PIP_CORNER", "asset": "still:aimg1", "zoom": "slow-in", "pip_side": "left"},
        {"start": 6, "end": 7, "layout": "FULLSCREEN_BROLL", "asset": "broll/clip.mp4", "zoom": "slow-in"},
        {"start": 7, "end": 8, "layout": "PIP_SIDE", "asset": "broll/diagram.png", "zoom": "none"},
        {"start": 8, "end": 9, "layout": "FULLSCREEN_BROLL", "asset": "gfx:intro", "zoom": "none"},
        {"start": 9, "end": 10, "layout": "fullscreen_broll", "asset": "broll/diagram.png", "zoom": "none"},
        {"start": 10, "end": 13, "layout": "FULLSCREEN_BROLL", "asset": "gfx:cta", "zoom": "none"},
    ]

    def still(self, path, size):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi",
                        "-i", "testsrc2=s=%s:d=1" % size, "-frames:v", "1", path], check=True, capture_output=True)

    def setup_dirs(self, tmp, rows=None):
        self.still(os.path.join(tmp, "inputs", "broll", "diagram.png"), "1920x1080")
        self.still(os.path.join(tmp, "work", "visuals", "aimg1.png"), "1280x720")
        self.still(os.path.join(tmp, "work", "visuals", "cta.png"), "1920x1080")
        self.still(os.path.join(tmp, "work", "visuals", "intro.png"), "1920x1080")
        subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                        "color=c=red:s=1920x1080:r=25:d=1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        os.path.join(tmp, "inputs", "broll", "clip.mp4")], check=True, capture_output=True)
        write(os.path.join(tmp, "prior", "broll_plan.json"), json.dumps({"duration": 13.0, "rows": rows or self.ROWS}))

    def fit(self, tmp, *extra, plan=None):
        return run(SAFE, "--plan", plan or os.path.join(tmp, "prior", "broll_plan.json"), "--broll", os.path.join(tmp, "inputs", "broll"),
                   "--visuals", os.path.join(tmp, "work", "visuals"), "--out-plan", os.path.join(tmp, "work", "safe.json"), *extra)

    def test_full_frame_stills_are_fitted_and_nothing_else_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.setup_dirs(tmp)
            code, text = self.fit(tmp)
            self.assertEqual(code, 0, text)
            new = read_json(os.path.join(tmp, "work", "safe.json"))["rows"]
            for i in (1, 2, 6):                                                # full-screen, PIP, and a lower-case layout name
                self.assertTrue(new[i]["asset"].startswith("still:capsafe-"), new[i])
                self.assertEqual(new[i]["zoom"], "none")
                self.assertEqual(png_size(os.path.join(tmp, "work", "visuals", new[i]["asset"][6:] + ".png")), (1920, 1080))
            for i in (0, 3, 4, 5, 7):                                          # video, side layout, cards and the end card
                self.assertEqual(new[i], self.ROWS[i])
            self.assertEqual(new[7]["asset"], "gfx:cta")

    def test_running_it_twice_does_not_shrink_a_still_twice(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.setup_dirs(tmp)
            self.assertEqual(self.fit(tmp)[0], 0)
            first = read_json(os.path.join(tmp, "work", "safe.json"))
            fitted = os.path.join(tmp, "work", "visuals", first["rows"][1]["asset"][6:] + ".png")
            with open(fitted, "rb") as fh:
                before = fh.read()
            code, text = self.fit(tmp, plan=os.path.join(tmp, "work", "safe.json"))
            self.assertEqual(code, 0, text)
            self.assertEqual(read_json(os.path.join(tmp, "work", "safe.json")), first)
            with open(fitted, "rb") as fh:
                self.assertEqual(fh.read(), before)

    def test_with_no_presenter_every_layout_shows_the_whole_frame(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.setup_dirs(tmp)
            code, text = self.fit(tmp, "--no-pip")
            self.assertEqual(code, 0, text)
            new = read_json(os.path.join(tmp, "work", "safe.json"))["rows"]
            self.assertTrue(new[4]["asset"].startswith("still:capsafe-"), new[4])   # PIP_SIDE row, presenter off

    def test_the_fitted_plan_builds(self):
        if not os.path.isfile(BUILD_SEGMENTS):
            self.skipTest("c-ffmpeg build-segments.py is not next to this recipe")
        with tempfile.TemporaryDirectory() as tmp:
            self.setup_dirs(tmp)
            self.assertEqual(self.fit(tmp)[0], 0)
            av = os.path.join(tmp, "av.mp4")
            subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                            "color=c=gray:s=1920x1080:d=13:r=25", "-f", "lavfi", "-i", "sine=f=300:d=13", "-shortest",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", av], check=True, capture_output=True)
            code, text = run(BUILD_SEGMENTS, "--plan", os.path.join(tmp, "work", "safe.json"), "--avatar", av,
                             "--avatar-raw", av, "--visuals", os.path.join(tmp, "work", "visuals"),
                             "--broll", os.path.join(tmp, "inputs", "broll"), "--out", os.path.join(tmp, "work", "seg"), "--dry-run")
            self.assertEqual(code, 0, text[-300:])
            self.assertIn("OK dry run: 8 segments", text)

    def test_a_missing_still_stops_and_names_the_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.setup_dirs(tmp)
            os.remove(os.path.join(tmp, "inputs", "broll", "diagram.png"))
            code, text = self.fit(tmp)
            self.assertEqual(code, 2, text)
            self.assertIn("row 2", text)
            self.assertFalse(os.path.exists(os.path.join(tmp, "work", "safe.json")))


class FontTests(unittest.TestCase):
    def test_the_bundled_font_is_inter_bold_with_its_licence(self):
        path = os.path.join(SKILL, "fonts", cap.FONT_FILE)
        with open(path, "rb") as fh:
            data = fh.read()
        self.assertEqual(data[:4], b"\x00\x01\x00\x00")                       # TrueType
        num = struct.unpack(">H", data[4:6])[0]
        names = {}
        for i in range(num):
            tag, _, off, ln = struct.unpack(">4sIII", data[12 + 16 * i:28 + 16 * i])
            if tag == b"name":
                table = data[off:off + ln]
                count, str_off = struct.unpack(">HH", table[2:6])
                for k in range(count):
                    pid, _, _, nid, length, o = struct.unpack(">6H", table[6 + 12 * k:18 + 12 * k])
                    if pid == 3:
                        names[nid] = table[str_off + o:str_off + o + length].decode("utf-16-be")
        self.assertEqual(names.get(1), "Inter")
        self.assertIn("Bold", names.get(2, "") + names.get(4, ""))
        self.assertIn("SIL OPEN FONT LICENSE", read(os.path.join(SKILL, "fonts", "OFL.txt")))
        self.assertLess(len(data), 200000)


@unittest.skipUnless(HAVE_ASS, "no ffmpeg with the ass filter")
class BurnTests(unittest.TestCase):
    def test_burn_draws_the_dark_box_and_the_active_word_colour(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_workdir(tmp)
            self.assertEqual(run(CAPTIONS, "build", "--dir", tmp)[0], 0)
            os.makedirs(os.path.join(tmp, "work"), exist_ok=True)
            subprocess.run([cap.find_ffmpeg_with_ass(), "-hide_banner", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                            "color=c=0x667788:s=640x360:r=25:d=12", "-f", "lavfi", "-i", "sine=f=300:d=12", "-shortest",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", os.path.join(tmp, "work", "loudnorm.mp4")],
                           check=True, capture_output=True)
            code, text = run(CAPTIONS, "burn", "--dir", tmp)
            self.assertEqual(code, 0, text)
            out = os.path.join(tmp, "saves", "mastered_video.mp4")
            self.assertTrue(os.path.getsize(out) > 0)
            self.assertTrue(os.path.isfile(os.path.join(tmp, "work", "fonts", cap.FONT_FILE)))
            t = 1.0                                                              # inside the first sentence
            raw = subprocess.run([cap.find_ffmpeg_with_ass(), "-v", "error", "-nostdin", "-ss", str(t), "-i", out, "-frames:v", "1",
                                  "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True).stdout
            self.assertEqual(len(raw), 640 * 360 * 3)
            navy = sum(1 for i in range(0, len(raw), 3) if abs(raw[i] - 15) < 14 and abs(raw[i + 1] - 23) < 14 and abs(raw[i + 2] - 42) < 14)
            orange = sum(1 for i in range(0, len(raw), 3) if raw[i] > 200 and 80 < raw[i + 1] < 150 and raw[i + 2] < 60)
            self.assertGreater(navy, 1500)                                       # the box
            self.assertGreater(orange, 20)                                       # the active word

    def test_burn_stops_when_the_ffmpeg_has_no_ass_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = os.path.join(tmp, "ffmpeg")
            write(stub, "#!/usr/bin/env bash\necho ' T.. scale  V->V  scale'\n")
            os.chmod(stub, os.stat(stub).st_mode | stat.S_IEXEC)
            write(os.path.join(tmp, "work", "loudnorm.mp4"), "x")
            write(os.path.join(tmp, "work", "captions.ass"), "x")
            code, text = run(CAPTIONS, "burn", "--dir", tmp, env=dict(os.environ, CFW_FFMPEG=stub))
            self.assertEqual(code, 2, text)
            self.assertIn("has no ass filter", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
