#!/usr/bin/env python3
"""Fail-closed local stage checks. Stdlib only; ffmpeg/ffprobe stay offline.

The pinned Spotlight bundle's eval runner skips unsupported stage guards and
leaves vision pending. This adapter implements those guards without editing the
bundle. `evidence RECIPE WORKDIR STEP` writes a PENDING review, never a PASS.
"""
from __future__ import annotations

import array
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unicodedata


class Invalid(ValueError):
    """Only fixed, owner-safe messages may cross this boundary."""


def require(ok: object, message: str) -> None:
    if not ok:
        raise Invalid(message)


def load(path: Path) -> object:
    def invalid_constant(value: str) -> None:
        raise Invalid("JSON contains a non-finite number.")
    def unique(pairs: list) -> dict:
        result = {}
        for key, value in pairs:
            require(key not in result, "JSON contains duplicate fields.")
            result[key] = value
        return result
    return json.loads(path.read_text(), parse_constant=invalid_constant, object_pairs_hook=unique)


def number(value: object) -> float:
    require(type(value) in (int, float) and math.isfinite(value), "Timing must use finite numbers.")
    return float(value)


def local(root: Path, name: str) -> Path:
    rel = Path(name)
    require(not rel.is_absolute() and rel.parts and ".." not in rel.parts, "Evidence must stay inside this stage.")
    path = root / rel
    require(not any(p.is_symlink() for p in (path, *path.parents)), "Linked artifacts are not allowed.")
    require(path.resolve().is_relative_to(root.resolve()), "Evidence must stay inside this stage.")
    return path


def command(args: list[str]) -> tuple[bytes, str]:
    if args[0] in ("ffmpeg", "ffprobe"):
        # Uploaded media is data, not permission to fetch remote playlists.
        args = [args[0], "-protocol_whitelist", "file,pipe", *args[1:]]
    p = subprocess.run(args, capture_output=True, timeout=300)
    require(p.returncode == 0, "Media could not be decoded or measured.")
    return p.stdout, p.stderr.decode("utf-8", "replace")


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return "sha256:" + value.hexdigest()


def probe(path: Path) -> dict:
    out, _ = command(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)])
    return json.loads(out)


def duration(path: Path) -> float:
    d = float(probe(path)["format"]["duration"])
    require(math.isfinite(d) and d > 0, "Media duration is invalid.")
    return d


def dimensions(path: Path) -> None:
    videos = [s for s in probe(path)["streams"] if s["codec_type"] == "video"]
    require(videos and (videos[0]["width"], videos[0]["height"]) == (1080, 1920), "Frame must be 1080 by 1920.")


def decode(path: Path, kind: str) -> None:
    streams = probe(path)["streams"]
    required = "video" if kind in ("video", "image") else "audio"
    require(any(s["codec_type"] == required for s in streams), "Required media stream is missing.")
    command(["ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"])


# Recipes whose finished reel can leave assemble quieter than the gate.
# Spotlight seals inside evidence mode, before qa/review.json records hashes.
# PIP has no review-hash contract; run seals it immediately before qa_gate.
# A file already inside the integrated target is not encoded again.
FINAL_LOUDNESS_RECIPES = ("p-reels-spotlight", "p-reels-pip")
_LOUDNESS_NUMBER = re.compile(r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)")
# Documented default. The qa_gate comparison (-14 within 1.5) stays literal.
_DEFAULT_I, _DEFAULT_TP, _DEFAULT_LRA = -14.0, -1.5, 11.0
_DEFAULT_LOUDNORM = "loudnorm=I=-14:TP=-1.5:LRA=11"
_LOUDNESS_TOLERANCE = 1.5


def _finite(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return None
    return float(value)


def _acceptance_checks(spec: object) -> list[dict]:
    if not isinstance(spec, dict):
        return []
    rows = [c for c in spec.get("checks") or [] if isinstance(c, dict)]
    steps = spec.get("steps") or {}
    if isinstance(steps, dict):
        for step in steps.values():
            if isinstance(step, dict):
                rows.extend(c for c in step.get("checks") or [] if isinstance(c, dict))
    return rows


def recipe_loudness_target(recipe: Path | None) -> tuple[float, float, float]:
    """Integrated LUFS, true peak, LRA. Recipe declaration wins; else -14 / -1.5 / 11."""
    integrated, tp, lra = _DEFAULT_I, _DEFAULT_TP, _DEFAULT_LRA
    if recipe is None or not (recipe / "acceptance.json").is_file():
        return integrated, tp, lra
    best: tuple[int, dict] | None = None
    for check in _acceptance_checks(load(recipe / "acceptance.json")):
        declared = _finite(check.get("target"))
        if declared is None:
            declared = _finite(check.get("lufs"))
        if declared is None:
            declared = _finite(check.get("I"))
        if declared is None or check.get("type") not in ("qa_gate", "loudness"):
            continue
        cid = str(check.get("id") or "")
        rank = 3 if check.get("type") == "qa_gate" else 2 if "final" in cid else 1
        if best is None or rank > best[0]:
            best = (rank, check)
    if best is None:
        return integrated, tp, lra
    check = best[1]
    found = _finite(check.get("target"))
    if found is None:
        found = _finite(check.get("lufs"))
    if found is None:
        found = _finite(check.get("I"))
    if found is not None:
        integrated = found
    for key in ("tp", "true_peak", "TP"):
        found = _finite(check.get(key))
        if found is not None:
            tp = found
            break
    found = _finite(check.get("lra"))
    if found is None:
        found = _finite(check.get("LRA"))
    if found is not None:
        lra = found
    return integrated, tp, lra


def _loudnorm_number(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "0") else text


def loudnorm_filter(integrated: float, tp: float, lra: float) -> str:
    if (integrated, tp, lra) == (_DEFAULT_I, _DEFAULT_TP, _DEFAULT_LRA):
        return _DEFAULT_LOUDNORM
    return f"loudnorm=I={_loudnorm_number(integrated)}:TP={_loudnorm_number(tp)}:LRA={_loudnorm_number(lra)}"


def _loudness_stat(stats: dict, key: str) -> str:
    raw = stats.get(key)
    require(not isinstance(raw, bool) and isinstance(raw, (int, float, str)), "Loudness measurement is incomplete.")
    text = raw.strip() if isinstance(raw, str) else str(raw)
    require(_LOUDNESS_NUMBER.fullmatch(text), "Loudness measurement is not finite.")
    require(math.isfinite(float(text)), "Loudness measurement is not finite.")
    return text


def integrated_lufs(path: Path) -> float:
    # Same summary line the unchanged qa_gate reads.
    _, err = command(["ffmpeg", "-hide_banner", "-i", str(path), "-af", "ebur128", "-f", "null", "-"])
    values = re.findall(r"I:\s*(-?[0-9.]+) LUFS", err)
    require(values, "Loudness measurement is incomplete.")
    value = float(values[-1])
    require(math.isfinite(value), "Loudness measurement is not finite.")
    return value


def normalize_loudness(path: Path, recipe: Path | None = None) -> None:
    """Two-pass linear loudnorm. Copy video; re-encode audio only.

    Default target is I=-14:TP=-1.5:LRA=11. A recipe acceptance check of type
    qa_gate or loudness can declare target, tp and lra. A file already within
    1.5 LU of the integrated target is left untouched.
    """
    require(not path.is_symlink() and path.is_file() and path.stat().st_size > 0, "Loudness input is missing.")
    streams = probe(path)["streams"]
    has_video = any(s.get("codec_type") == "video" for s in streams)
    require(any(s.get("codec_type") == "audio" for s in streams), "Loudness input has no audio.")
    integrated, tp, lra = recipe_loudness_target(recipe)
    if abs(integrated_lufs(path) - integrated) <= _LOUDNESS_TOLERANCE:
        return
    prefix = loudnorm_filter(integrated, tp, lra)
    out, err = command(["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-vn",
                         "-af", prefix + ":print_format=json", "-f", "null", "-"])
    stats = None
    for blob in re.findall(r"\{[^{}]*\}", err + "\n" + out.decode("utf-8", "replace")):
        try:
            parsed = json.loads(blob)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "input_i" in parsed:
            stats = parsed
    require(isinstance(stats, dict), "Loudness measurement did not return stats.")
    filt = (
        prefix
        + f":measured_I={_loudness_stat(stats, 'input_i')}"
        + f":measured_TP={_loudness_stat(stats, 'input_tp')}"
        + f":measured_LRA={_loudness_stat(stats, 'input_lra')}"
        + f":measured_thresh={_loudness_stat(stats, 'input_thresh')}"
        + f":offset={_loudness_stat(stats, 'target_offset')}"
        + ":linear=true"
    )
    dest = path.with_name(path.name + ".cfw-loudnorm.mp4")
    backup = path.with_name(path.name + ".cfw-loudnorm-prev.mp4")
    kind = "video" if has_video else "audio"
    args = ["ffmpeg", "-y", "-i", str(path), "-af", filt]
    if has_video:
        args += ["-c:v", "copy"]
    else:
        args += ["-vn"]
    args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2", "-movflags", "+faststart", str(dest)]
    moved = False
    try:
        command(args)
        decode(dest, kind)
        path.replace(backup)
        moved = True
        dest.replace(path)
        decode(path, kind)
        moved = False
        backup.unlink()
    except Exception:
        if moved and backup.exists():
            if path.exists():
                path.unlink()
            backup.replace(path)
        raise
    finally:
        if dest.exists():
            dest.unlink()
        if moved and backup.exists():
            if path.exists():
                path.unlink()
            backup.replace(path)


def frame(path: Path, t: float) -> bytes:
    out, _ = command(["ffmpeg", "-v", "error", "-ss", str(t), "-i", str(path),
                      "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-"])
    require(len(out) == 1080 * 1920 * 3, "Review frame is missing or unreadable.")
    return out


def luma(path: Path, times: list[float], floor: float = 16) -> None:
    for t in times:
        _, err = command(["ffmpeg", "-hide_banner", "-ss", str(t), "-i", str(path),
                          "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG",
                          "-frames:v", "1", "-f", "null", "-"])
        values = re.findall(r"lavfi.signalstats.YAVG=([0-9.]+)", err)
        require(values and (float(values[0]) - 16) * 255 / 219 >= floor,
                "A required frame is black or too dark.")


def latin(text: str) -> bool:
    for c in text:
        category, name = unicodedata.category(c), unicodedata.name(c, "")
        if category.startswith("L") and "LATIN" not in name:
            return False
        if category.startswith("M") and not name.startswith("COMBINING "):
            return False
        if c.isdecimal() and c not in "0123456789":
            return False
    return True


def interval(row: dict, end: float, start_key: str = "start", end_key: str = "end") -> tuple[float, float]:
    a, b = number(row[start_key]), number(row[end_key])
    require(0 <= a < b <= end, "A timed window is outside its media.")
    return a, b


class Spotlight:
    def __init__(self, recipe: Path, work: Path, step: str) -> None:
        self.recipe, self.work, self.step = recipe, work, step
        self.spec = load(recipe / "acceptance.json")
        self.review_checked = False
        self.bed_duration: float | None = None

    def path(self, name: str) -> Path:
        return local(self.work, name)

    def bed(self) -> float:
        if self.bed_duration is None:
            self.bed_duration = duration(self.path("prior/voice_track.mp4"))
        return self.bed_duration

    def plan(self) -> dict:
        return load(self.path("saves/edit_plan.json" if self.step == "plan_edit" else "prior/edit_plan.json"))

    def beats(self) -> list:
        name = "saves/beat_list.json" if self.step == "plan_broll" else "prior/beat_list.json"
        path = self.path(name)
        if not path.exists():
            require(not any(self.path("inputs/broll").glob("*")), "B-roll was supplied but its beat list is missing.")
            return []
        rows = load(path)["beats"]
        require(isinstance(rows, list), "Beat list must contain an array.")
        return rows

    def windows(self) -> list[tuple[float, float]]:
        return [interval(t, self.bed()) for t in self.plan()["takeovers"]] + [
            interval(b, self.bed()) for b in self.beats() if b["kind"] == "broll"]

    def artifact(self) -> Path:
        names = {"prepare_footage": "voice_track", "render_scenes": "rendered_scenes",
                 "assemble": "assembled_video", "final_checks": "final_video"}
        return self.path("saves/" + names[self.step] + ".mp4")

    def words(self, spec: dict) -> None:
        words = load(self.path("saves/transcripts.json"))["words"]
        require(isinstance(words, list) and len(words) >= spec["min_items"], "Transcript has no words.")
        bed, previous = self.bed(), -1.0
        for word in words:
            require(isinstance(word["text"], str) and any(c.isalnum() for c in word["text"]), "Transcript contains an empty word.")
            a, _ = interval(word, bed)
            require(a >= previous, "Transcript words are out of order.")
            previous = a
        require(abs(words[-1]["end"] - bed) <= spec["tail_tolerance_s"], "Transcript does not reach the end of the voice bed.")

    def plan_guard(self, spec: dict) -> None:
        p, bed = self.plan(), self.bed()
        require(abs(number(p["duration"]) - bed) <= 0.5, "Plan duration does not match the voice bed.")
        for key in ("bg", "accent", "fg"):
            require(re.fullmatch(r"#[0-9a-fA-F]{6}", p["brand"][key]), "Brand colours must be six-digit hex values.")
        require(latin(json.dumps(p, ensure_ascii=False)), "Plan contains non-Latin letters.")
        groups = p["caption_groups"]
        require(isinstance(groups, list) and groups, "Caption groups are missing.")
        previous = 0.0
        for group in groups:
            a, b = interval(group, bed)
            require(a >= previous, "Caption groups overlap or are out of order.")
            require(group["words"], "Caption group contains no words.")
            word_start = a
            for word in group["words"]:
                s, e = interval(word, b, "s", "e")
                require(s >= word_start and s >= a and e <= b and word["w"].strip(), "Caption word timing is invalid.")
                word_start = e
            require(sum(bool(w.get("em")) for w in group["words"]) <= 1, "Caption group has multiple emphasis words.")
            previous = b
        require(abs(previous - bed) <= spec["caption_tail_tolerance_s"], "Captions do not reach the end of the voice bed.")
        cover = number(p["cover_at"])
        require(spec["cover_at_min_s"] <= cover < bed, "Cover time is outside the permitted window.")
        previous, template = -2.0, None
        require(isinstance(p["takeovers"], list) and 2 <= len(p["takeovers"]) <= 4, "Plan must contain two to four takeovers.")
        for tk in p["takeovers"]:
            a, b = interval(tk, bed)
            require(a >= 2 and b <= bed - 2 and spec["takeover_min_s"] <= b - a <= spec["takeover_max_s"], "Takeover length or placement is invalid.")
            require(a - previous >= 4 and tk["template"] != template, "Takeovers need speaker spacing and distinct templates.")
            require(not a <= cover <= b, "Cover time falls inside a takeover.")
            require(tk["template"] in ("tk-stat", "tk-keyword", "tk-list", "tk-quote", "tk-typing-ui") and isinstance(tk["fill"], dict) and tk["fill"], "Takeover template or content is missing.")
            previous, template = b, tk["template"]

    def beats_guard(self, spec: dict) -> None:
        bed, rows = self.bed(), self.beats()
        broll = [b for b in rows if b["kind"] == "broll"]
        require(len(broll) >= spec["min_broll_beats"], "No b-roll beats were planned.")
        previous = 0.0
        for row in rows:
            a, b = interval(row, bed)
            require(a >= previous and row["kind"] in ("broll", "graphics", "avatar"), "Beat kinds or ordering are invalid.")
            previous = b
        for row in broll:
            a, b = interval(row, bed)
            require(spec["edge_margin_s"] <= a and b <= bed - spec["edge_margin_s"], "B-roll intrudes into the opening or ending.")
            clip = row["broll"]
            require(clip["clip"].startswith("inputs/broll/"), "B-roll must reference a supplied clip.")
            source = self.path(clip["clip"])
            decode(source, "video")
            interval(clip, duration(source), "in", "out")
            require(abs((clip["out"] - clip["in"]) - (b - a)) <= 0.1, "B-roll trim does not cover its planned window.")
            for tk in self.plan()["takeovers"]:
                require(b <= tk["start"] or a >= tk["end"], "B-roll overlaps a graphics takeover.")

    def voice(self) -> None:
        bed, output = self.path("prior/voice_track.mp4"), self.artifact()
        offset = 0.4 if self.step == "final_checks" else 0.0
        require(abs(duration(output) - duration(bed) - offset) < (0.1 if offset else 0.15), "Voice bed duration or cover offset has changed.")
        def pcm(path: Path, start: float) -> array.array:
            out, _ = command(["ffmpeg", "-v", "error", "-i", str(path), "-ss", str(start),
                              "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"])
            samples = array.array("h", out)
            if sys.byteorder != "little":
                samples.byteswap()
            return samples
        original, actual = pcm(bed, 0), pcm(output, offset)
        require(abs(len(original) - len(actual)) <= 800, "Voice track is truncated.")
        # Compare every half second, not just the existence of an audio stream.
        # Correlation permits SFX/re-encoding but rejects cut, replaced or retimed VO.
        for i in range(0, min(len(original), len(actual)) - 4000 + 1, 4000):
            x, y = original[i:i + 4000], actual[i:i + 4000]
            xx, yy = sum(v * v for v in x), sum(v * v for v in y)
            if xx > 4000:
                corr = sum(a * b for a, b in zip(x, y)) / math.sqrt(xx * yy) if yy else 0
                require(corr >= 0.90, "Narration differs from the sealed voice bed.")
        for a, b in self.windows():
            section = actual[int(a * 8000):int(b * 8000)]
            require(section and sum(v * v for v in section) > len(section), "Narration is silent during a takeover.")

    def evidence_sources(self) -> dict[str, str]:
        result = {}
        for folder in ("saves", "prior", "inputs/broll"):
            for path in sorted(self.path(folder).rglob("*")):
                if path.is_file():
                    name = path.relative_to(self.work).as_posix()
                    result[name] = digest(self.path(name))
        return result

    def evidence_frames(self) -> list[tuple[str, float]]:
        source = self.artifact().relative_to(self.work).as_posix()
        d = duration(self.artifact())
        offset = 0.4 if self.step == "final_checks" else 0
        times = {0.0, *(round(d * p, 3) for p in (0.05, 0.2, 0.4, 0.6, 0.8, 0.95))}
        for a, b in self.windows():
            times.update(round(t + offset, 3) for t in (a, (a + b) / 2, b - 1 / 30))
        rows = [(source, t) for t in sorted(times)]
        if self.step == "final_checks":
            rows += [("saves/cover.png", 0.0), ("prior/assembled_video.mp4", number(self.plan()["cover_at"]))]
        return rows

    def review_ids(self) -> list[str]:
        return [c["id"] for c in self.spec["checks"] if c["type"] == "perceptual"] if self.step == "final_checks" else ["vo_continuous_bed"]

    def make_evidence(self) -> None:
        # Hash the sealed deliverable. Sealing later, inside qa_gate, rewrites
        # saves/final_video.mp4 and every later review() reports stale evidence.
        if self.step == "final_checks":
            normalize_loudness(self.artifact(), self.recipe)
        rows = []
        self.path("qa").mkdir(exist_ok=True)
        for i, (source, t) in enumerate(self.evidence_frames()):
            name = f"qa/frame-{i:03d}.png"
            target = self.path(name)
            command(["ffmpeg", "-v", "error", "-y", "-ss", str(t), "-i", str(self.path(source)), "-frames:v", "1", str(target)])
            rows.append({"id": str(i), "source": source, "time": t, "path": name, "sha256": digest(target)})
        doc = {"schemaVersion": 1, "artifacts": self.evidence_sources(), "specSha256": digest(self.recipe / "acceptance.json"),
               "frames": rows, "checks": [{"id": cid, "status": "PENDING", "reviewer": "", "observations": "",
               "frameIds": [r["id"] for r in rows], "audioReviewed": False} for cid in self.review_ids()]}
        self.path("qa/review.json").write_text(json.dumps(doc, indent=2) + "\n")

    def review(self, cid: str) -> None:
        doc = load(self.path("qa/review.json"))
        require(doc["schemaVersion"] == 1 and doc["artifacts"] == self.evidence_sources()
                and doc["specSha256"] == digest(self.recipe / "acceptance.json"), "QA evidence is stale; review the current outputs.")
        rows = doc["checks"]
        require(len({r["id"] for r in rows}) == len(rows), "QA evidence contains duplicate checks.")
        row = next((r for r in rows if r["id"] == cid), {})
        require(row.get("status") == "PASS" and isinstance(row.get("reviewer"), str)
                and row["reviewer"].strip() and isinstance(row.get("observations"), str)
                and row["observations"].strip(), "Required visual review is absent, failed or pending.")
        require(cid != "vo_continuous_bed" or row.get("audioReviewed") is True, "Voice continuity needs a listening review.")
        frames = doc["frames"]
        require(len({r["id"] for r in frames}) == len(frames) and set(row["frameIds"]) == {r["id"] for r in frames}, "Review must reference every required frame.")
        if self.review_checked:
            return
        require([(r["source"], number(r["time"])) for r in frames] == self.evidence_frames(), "Required review frames are missing.")
        for r in frames:
            require(r["path"].startswith("qa/") and r["path"].endswith(".png"), "Review evidence must be a local PNG frame.")
            evidence = self.path(r["path"])
            require(digest(evidence) == r["sha256"], "Review frame has changed.")
            require(frame(evidence, 0) == frame(self.path(r["source"]), r["time"]), "Review frame does not match the current media.")
        self.review_checked = True

    def check(self, cid: str) -> None:
        specs = self.spec["checks"] if self.step in ("assemble", "final_checks") else self.spec["steps"]["speakerbed" if self.step == "prepare_footage" else self.step]["checks"]
        c = next((c for c in specs if c["id"] == cid), None)
        require(c is not None, "Required validator is not implemented.")
        typ = c["type"]
        if typ == "json_words_nonempty":
            self.words(c)
        elif typ == "spotlight_plan_guard":
            self.plan_guard(c)
        elif typ == "spotlight_beats_guard":
            self.beats_guard(c)
        elif typ == "dims":
            dimensions(self.artifact())
            if self.step == "prepare_footage":
                require(20 <= duration(self.artifact()) <= 60, "Voice bed must last 20 to 60 seconds.")
                require(any(s["codec_type"] == "audio" for s in probe(self.artifact())["streams"]), "Voice bed has no audio.")
        elif typ == "duration_window":
            require(c["min_s"] <= duration(self.artifact()) <= c["max_s"], "Duration is outside the accepted window.")
        elif typ in ("luma_floor", "luma_floor_windows"):
            media, d = self.artifact(), duration(self.artifact())
            times = [round(d * p, 2) for p in c["samples"]]
            if typ == "luma_floor_windows":
                dimensions(media)
                require(abs(d - self.bed()) <= c["duration_tolerance_s"], "Scene duration differs from the voice bed.")
                times += [t for a, b in self.windows() for t in (a, (a + b) / 2, b - 1 / 30)]
            luma(media, times, c["floor"])
        elif typ == "qa_gate":
            # The installed gate is useful, but treats unmeasurable loudness and
            # brightness as advisory. Require those measurements independently.
            with tempfile.TemporaryDirectory(prefix="cfw-qa-") as tmp:
                command(["bash", str(self.recipe / ".hub/c-shorts-qa-gate/scripts/qa-gate.sh"),
                         str(self.artifact()), "--format", c["format"], "--outdir", tmp])
            _, err = command(["ffmpeg", "-hide_banner", "-i", str(self.artifact()), "-af", "ebur128", "-f", "null", "-"])
            values = re.findall(r"I:\s*(-?[0-9.]+) LUFS", err)
            require(values and -15.5 <= float(values[-1]) <= -12.5, "Loudness must be minus 14 LUFS, within 1.5 LUFS.")
            luma(self.artifact(), [0])
        elif typ == "perceptual":
            if cid == "vo_continuous_bed":
                self.voice()
            elif cid == "no_black_empty_frames":
                _, err = command(["ffmpeg", "-hide_banner", "-i", str(self.artifact()), "-vf",
                                  "signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-an", "-f", "null", "-"])
                values = re.findall(r"lavfi.signalstats.YAVG=([0-9.]+)", err)
                require(values and all(float(v) > 16 for v in values), "The reel contains a black or empty frame.")
            elif cid == "takeover_frames_not_blank":
                luma(self.artifact(), [t + 0.4 for a, b in self.windows() for t in (a, (a + b) / 2, b - 1 / 30)])
            elif cid == "latin_script_only":
                require(latin(json.dumps(load(self.path("saves/captions.json")), ensure_ascii=False))
                        and latin(json.dumps(self.plan()["caption_groups"], ensure_ascii=False)), "Captions contain non-Latin letters.")
            elif cid == "cover_is_moneyshot":
                dimensions(self.path("saves/cover.png"))
                luma(self.path("saves/cover.png"), [0])
            self.review(cid)
        else:
            raise Invalid("Required validator is not implemented.")


def instructions(helper: Path, recipe: Path, step: str, local: bool = False) -> None:
    if step == "prepare_footage":
        print("\n## Local-mode acceptance alignment\n"
              "Normalize the sealed voice bed ONCE to I=-14:TP=-1.5:LRA=11. "
              "This supersedes the pinned step's I=-16 sample for local mode: "
              "the unchanged final gate requires -14 LUFS within 1.5 LUFS. "
              "Keep the complete narration and do not normalize again in later stages.\n")
    if step not in ("assemble", "final_checks"):
        return
    # Spotlight local evidence path. PIP has no review-hash contract.
    # Non-local prompts do not get this block: nothing there checks it.
    if recipe.name != "p-reels-spotlight" or not local:
        return
    print(f"""\n## Required local QA evidence (supersedes prose-only QA)
After ALL saves are complete, run:
python3 {json.dumps(str(helper))} evidence {json.dumps(str(recipe))} . {step}
This writes qa/review.json and lossless frames. It NEVER passes review for you.
Read every generated frame with your image-reading tool; listen to the output
and compare the sealed voice bed for vo_continuous_bed. Apply every criterion
in the recipe acceptance.json, including captions, skin tones, takeover clips
and the cover comparison. In qa/review.json set each reviewed check's status to
PASS or FAIL, reviewer to your engine/reviewer identity, observations to specific
visual findings, and audioReviewed=true only after listening for voice checks.
Keep artifacts/spec hashes, frames and frameIds unchanged. PENDING, missing,
stale, unreadable or failed evidence blocks completion. Re-generate and review
after any artifact edit. Do not use the eval runner's exit 0 or NEEDS_VISION as
approval. The harness independently decodes saves and runs objective checks.
""")
    if step == "final_checks":
        print("\nThe harness already sealed prior/assembled_video.mp4 before this step. "
              "The evidence command normalises saves/final_video.mp4 to the same target "
              "BEFORE it writes qa/review.json when the file is still outside range. "
              "Run evidence after every save exists and before you review frames. "
              "Do not replace or loudnorm final_video after evidence. A file already "
              "inside the target is left unchanged, so a retry does not re-encode. "
              "The QA gate target stays minus 14 LUFS within 1.5 LUFS.\n")


def run(order: Path, recipe: Path, work: Path, sid: str) -> int:
    manifest = load(order)["manifest"]
    steps = [s for s in manifest["steps"] if s["id"] == sid]
    require(len(steps) == 1, "Stage declaration is invalid.")
    step = steps[0]
    spotlight = Spotlight(recipe, work, sid) if manifest["recipe"] == "p-reels-spotlight" else None
    rows = []
    ext = {"video": "mp4", "image": "png", "audio": "mp3", "json": "json", "text": "md"}
    def record(cid: str, fn) -> None:
        try:
            fn()
            rows.append({"id": cid, "passed": True})
        except Invalid as exc:
            rows.append({"id": cid, "passed": False, "detail": str(exc)})
        except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, StopIteration, subprocess.SubprocessError):
            rows.append({"id": cid, "passed": False, "detail": "Required artifact or QA evidence is missing, malformed or unreadable."})
    for save in step.get("saves", []):
        def validate_save() -> None:
            require(re.fullmatch(r"[a-z][a-z0-9_]{0,119}", save["id"]), "Save declaration is invalid.")
            path = local(work, "saves/" + save["id"] + "." + ext[save["kind"]])
            require(path.is_file() and path.stat().st_size > 0, "Required save is missing or empty.")
            if save["kind"] == "json":
                load(path)
            elif save["kind"] in ("video", "image", "audio"):
                decode(path, save["kind"])
            else:
                require(path.read_text().strip(), "Required text save is empty.")
        record("save:" + save["id"], validate_save)
    ids = [c["id"] for c in step.get("checks", [])]
    require(len(ids) == len(set(ids)), "Required checks contain duplicate declarations.")
    for cid in ids:
        def validate_check(cid: str = cid) -> None:
            require(re.fullmatch(r"[a-z][a-z0-9_]{0,119}", cid), "Check declaration is invalid.")
            # PIP seals here, before its gate. Spotlight already sealed inside
            # evidence mode; rewriting saves/final_video.mp4 after qa/review.json
            # would fail every later review-backed check as stale. If that
            # evidence file is absent, seal once so the gate still sees -14.
            if cid == "qa_gate" and manifest.get("recipe") in FINAL_LOUDNESS_RECIPES:
                sealed_evidence = manifest.get("recipe") == "p-reels-spotlight" and local(work, "qa/review.json").is_file()
                if not sealed_evidence:
                    normalize_loudness(local(work, "saves/final_video.mp4"), recipe)
            if spotlight:
                spotlight.check(cid)
            else:
                script = local(recipe, "checks/" + cid + ".sh")
                require(script.is_file(), "Required validator is missing; update the recipe before retrying.")
                p = subprocess.run(["bash", str(script), str(work)], capture_output=True, timeout=300)
                require(p.returncode == 0, "Required recipe validation failed. Correct the stage output and retry.")
        record(cid, validate_check)
    # Save validation is mandatory, but only declared check IDs belong in a
    # successful report. Social rejects extra/undeclared success checks.
    saves = rows[:len(step.get("saves", []))]
    reported = rows[len(saves):]
    failures = [row for row in saves if not row["passed"]]
    if failures:
        reported = [{"id": "validation", "passed": False, "detail": failures[0]["detail"]}, *reported]
    print(json.dumps(reported))
    return 0 if all(row["passed"] for row in rows) else 1


def main() -> int:
    try:
        mode, *args = sys.argv[1:]
        if mode == "instructions":
            instructions(Path(__file__).resolve(), Path(args[0]).resolve(), args[1], len(args) > 2 and args[2] == "local")
        elif mode == "evidence":
            Spotlight(Path(args[0]).resolve(), Path(args[1]).resolve(), args[2]).make_evidence()
        elif mode == "run":
            return run(Path(args[0]), Path(args[1]).resolve(), Path(args[2]).resolve(), args[3])
        elif mode == "loudnorm":
            require(1 <= len(args) <= 2, "Unknown validation command.")
            recipe = Path(args[1]).resolve() if len(args) == 2 else None
            try:
                normalize_loudness(Path(args[0]), recipe)
            except Invalid as exc:
                print(str(exc))
                return 1
        else:
            raise Invalid("Unknown validation command.")
        return 0
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, subprocess.SubprocessError):
        print('[{"id":"validation","passed":false,"detail":"Stage validation could not run. Check the recipe and required local tools."}]')
        return 1


if __name__ == "__main__":
    sys.exit(main())
