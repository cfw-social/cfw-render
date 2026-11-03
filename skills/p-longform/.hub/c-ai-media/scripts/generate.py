#!/usr/bin/env python3
"""generate.py - one AI still from Kie.ai, saved as a PNG file.

Used by p-longform step 04 (build_visuals) for the optional AI stills. Python
standard library only. One call = one image = about 0.8 Kie credits on the default
model (z-image). It spends money, so it is guarded:

  * It needs the brand's Kie key in the environment as KIE_AI_API_KEY (what the CFW
    render worker exports from the order's brand keys). It reads no other name and no
    file: a worker-local key is never used. With no key it sends nothing, spends
    nothing and exits 3. The step then renders GFX cards instead.
  * The key goes only to api.kie.ai. A redirect on an API call is never followed, so
    the key cannot be forwarded to another host.
  * It never retries the create call (a retry could be charged twice). Status
    checks are free and are retried.
  * It never prints the key, the Authorization header or the result URL.

Usage
  generate.py --provider kie --aspect 16:9 --prompt "<prompt>" --out work/visuals/img_01.png
              [--model z-image] [--timeout 150] [--poll 5] [--dry-run]

Last line of stdout
  IMAGE_FILE: <path>        success; the PNG is at <path>
  IMAGE_FAILED: <reason>    failure (exit 1 or 3)
  A bad command line prints its problem on stderr and exits 2.

Exit codes
  0 image saved        1 Kie or network failure, rejected request, timeout, bad download
  2 bad arguments      3 no Kie key in the environment (nothing was sent)

--dry-run checks the arguments and the key, prints what it would send (never the key)
and exits 0 without any network call.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_BASE = "https://api.kie.ai"
DEFAULT_MODEL = "z-image"
UA = "cfw-render-generate/1.0"
MAX_IMAGE_BYTES = 25 * 1024 * 1024
KEY_NAME = "KIE_AI_API_KEY"
RUNNING = ("waiting", "queuing", "queued", "generating", "running", "processing", "pending")
DONE = ("success", "completed", "done")
FAILED = ("fail", "failed", "error")


class Usage(Exception):
    pass


class Failed(Exception):
    pass


def finish(ok, text, code):
    print(("IMAGE_FILE: " if ok else "IMAGE_FAILED: ") + text)
    sys.exit(code)


def find_key():
    return KEY_NAME, os.environ.get(KEY_NAME, "").strip()


def check_base(url):
    if url == DEFAULT_BASE:
        return url
    u = urllib.parse.urlparse(url)
    if u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and u.port:
        return url.rstrip("/")
    raise Usage("--base-url may only be %s (or a local http address for tests)" % DEFAULT_BASE)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect on a keyed call is returned as an error, never re-sent (the key would follow it)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class _HttpsOnlyRedirect(urllib.request.HTTPRedirectHandler):
    """The key-less image download may follow a CDN redirect, but only to https."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlparse(newurl).scheme != "https":
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def http(method, url, key=None, body=None, timeout=30):
    """Return (status, bytes). Raises Failed on a network problem."""
    headers = {"User-Agent": UA, "Accept": "application/json, image/*"}
    data = None
    if key:
        headers["Authorization"] = "Bearer " + key
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(_NoRedirect if key else _HttpsOnlyRedirect)
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read(MAX_IMAGE_BYTES + 1)
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read(65536)
        except Exception:
            return e.code, b""
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = getattr(e, "reason", e)
        raise Failed("network error talking to Kie (%s)" % type(reason).__name__)


def api_error(status, raw):
    """A short, safe description of an error reply: HTTP status, Kie code and message."""
    code = msg = ""
    try:
        j = json.loads(raw.decode("utf-8", "replace"))
        code = str(j.get("code", ""))
        msg = str(j.get("msg") or j.get("message") or "")
    except (ValueError, AttributeError):
        pass
    msg = re.sub(r"https?://\S+", "<url>", msg)[:160]
    hint = {401: " (the Kie key was refused)", 402: " (not enough Kie credits)"}.get(
        status if status in (401, 402) else int(code) if code.isdigit() and int(code) in (401, 402) else 0, "")
    return "HTTP %s, Kie code %s%s: %s" % (status, code or "-", hint, msg or "no message")


def to_png(tmp, out):
    """Move the downloaded bytes to `out` as a PNG (converting a JPEG or WEBP with ffmpeg)."""
    with open(tmp, "rb") as fh:
        head = fh.read(16)
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        os.replace(tmp, out)
        return
    if head.startswith(b"\xff\xd8\xff") or (head[:4] == b"RIFF" and head[8:12] == b"WEBP"):
        ff = shutil.which("ffmpeg") or next((p for p in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")
                                             if os.access(p, os.X_OK)), None)
        if not ff:
            raise Failed("Kie returned a JPEG/WEBP image and ffmpeg is not available to convert it")
        part = out + ".png.part"
        r = subprocess.run([ff, "-v", "error", "-y", "-i", tmp, "-frames:v", "1", "-f", "image2", "-c:v", "png", part],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        os.remove(tmp)
        if r.returncode != 0 or not os.path.getsize(part):
            if os.path.exists(part):
                os.remove(part)
            raise Failed("could not convert the downloaded image to PNG")
        os.replace(part, out)
        return
    os.remove(tmp)
    raise Failed("the download was not a PNG, JPEG or WEBP image")


def main(argv):
    ap = argparse.ArgumentParser(description="Generate one AI still with Kie.ai and save it as a PNG.",
                                 epilog="Needs the brand's KIE_AI_API_KEY in the environment.")
    ap.add_argument("--provider", default="kie", help="only 'kie' is supported")
    ap.add_argument("--aspect", default="16:9", help="aspect ratio such as 16:9, 1:1, 9:16")
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--out", required=True, help="PNG file to write")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="Kie model key (default z-image)")
    ap.add_argument("--timeout", type=int, default=150, help="seconds to wait for the image (default 150)")
    ap.add_argument("--poll", type=int, default=5, help="seconds between status checks (default 5)")
    ap.add_argument("--base-url", default=DEFAULT_BASE, help=argparse.SUPPRESS)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    if args.provider != "kie":
        raise Usage("--provider %r is not supported; only 'kie' is" % args.provider)
    if not re.match(r"^\d{1,2}:\d{1,2}$", args.aspect):
        raise Usage("--aspect must look like 16:9, got %r" % args.aspect)
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_./-]{0,63}$", args.model):
        raise Usage("--model %r is not a valid model key" % args.model)
    prompt = args.prompt.strip()
    if not prompt or len(prompt) > 4000:
        raise Usage("--prompt must be 1 to 4000 characters")
    if not args.out.lower().endswith(".png"):
        raise Usage("--out must end in .png")
    if not (10 <= args.timeout <= 1800 and 1 <= args.poll <= 60):
        raise Usage("--timeout must be 10..1800 and --poll 1..60 seconds")
    base = check_base(args.base_url)

    key_name, key = find_key()
    if args.dry_run:
        print("DRY RUN: would create one %s image (%s) with model %s -> %s" % (
            args.aspect, "key found in " + key_name if key else "NO KEY, it would stop with exit 3", args.model, args.out))
        print("no request was sent")
        return 0
    if not key:
        finish(False, "no Kie key in the environment (set KIE_AI_API_KEY); nothing was sent and nothing was spent", 3)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)

    # 1. Create the task. Exactly once: a retry could be charged twice.
    try:
        status, raw = http("POST", base + "/api/v1/jobs/createTask", key,
                           {"model": args.model, "input": {"prompt": prompt, "aspect_ratio": args.aspect}})
    except Failed as e:
        raise Failed("%s; the request was not repeated, so you cannot be charged twice" % e)
    try:
        reply = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        reply = None
    task = ((reply or {}).get("data") or {}).get("taskId") if isinstance(reply, dict) else None
    if status != 200 or not isinstance(reply, dict) or str(reply.get("code")) != "200" or not task:
        raise Failed("Kie did not accept the request: " + api_error(status, raw))
    task = str(task)
    if not re.match(r"^[A-Za-z0-9_-]{1,128}$", task):
        raise Failed("Kie returned an unusable task id")

    # 2. Poll. Status checks are free, so a short network blip is retried.
    deadline = time.time() + args.timeout
    url = None
    blips = 0
    while True:
        time.sleep(args.poll)
        try:
            status, raw = http("GET", base + "/api/v1/jobs/recordInfo?taskId=" + urllib.parse.quote(task), key, timeout=20)
        except Failed:
            blips += 1
            if blips > 3:
                raise
            status, raw = 0, b""
        if status == 200:
            try:
                data = (json.loads(raw.decode("utf-8", "replace")) or {}).get("data") or {}
            except ValueError:
                data = {}
            state = str(data.get("state", "")).lower()
            if state in DONE:
                try:
                    urls = json.loads(data.get("resultJson") or "{}").get("resultUrls") or []
                except (ValueError, AttributeError):
                    urls = []
                if not urls:
                    raise Failed("Kie finished task %s but returned no image" % task)
                url = str(urls[0])
                break
            if state in FAILED:
                why = re.sub(r"https?://\S+", "<url>", str(data.get("failMsg") or data.get("error") or ""))[:160]
                raise Failed("Kie task %s failed: %s" % (task, why or "no reason given"))
        elif status in (401, 402, 403, 404):
            raise Failed("Kie refused the status check: " + api_error(status, raw))
        if time.time() >= deadline:
            raise Failed("timed out after %ds waiting for Kie task %s (it may still finish on Kie; it was not "
                         "retried so you are not charged twice)" % (args.timeout, task))

    # 3. Download. The result URL is never printed.
    parsed = urllib.parse.urlparse(url)
    local = base != DEFAULT_BASE and parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")
    if parsed.scheme != "https" and not local:
        raise Failed("Kie returned a result address that is not https")
    status, raw = http("GET", url, None, timeout=60)
    if status != 200 or not raw:
        raise Failed("could not download the image (HTTP %s)" % status)
    if len(raw) > MAX_IMAGE_BYTES:
        raise Failed("the image is larger than %d MB" % (MAX_IMAGE_BYTES // (1024 * 1024)))
    tmp = args.out + ".download"
    with open(tmp, "wb") as fh:
        fh.write(raw)
    to_png(tmp, args.out)
    finish(True, "%s (%d bytes, model %s)" % (args.out, os.path.getsize(args.out), args.model), 0)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]) or 0)
    except Usage as e:
        sys.stderr.write("generate.py: %s\n" % e)
        sys.exit(2)
    except Failed as e:
        finish(False, str(e), 1)
    except KeyboardInterrupt:
        sys.exit(130)
