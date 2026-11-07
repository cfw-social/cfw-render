#!/usr/bin/env python3
"""generate.py - one AI still from Kie.ai, saved as a PNG file.

Used by p-longform step 04 (build_visuals) for the optional AI stills, and by
p-ai-character steps 02-03 for the character reference and the scenes. Python
standard library only. One call = one image = about 0.8 Kie credits on the default
model (z-image). It spends money, so it is guarded:

  * It needs the brand's Kie key in the environment as KIE_AI_API_KEY (what the CFW
    render worker exports from the order's brand keys). It reads no other name and no
    file: a worker-local key is never used. With no key it sends nothing, spends
    nothing and exits 3. The step then renders GFX cards instead.
  * The key goes only to api.kie.ai and, with --ref, to Kie's File Upload API host
    kieai.redpandaai.co. A redirect on a keyed call is never followed, so the key
    cannot be forwarded to another host.
  * It never retries the create call (a retry could be charged twice). Status
    checks are free and are retried.
  * It never prints the key, the Authorization header, an uploaded reference URL or
    the result URL.

Reference images (--ref, image-to-image)
  Kie's image-to-image models read the reference from input.input_urls as hosted
  file URLs, "File URL after upload, not file content" (docs.kie.ai/market/gpt-image/
  1-5-image-to-image). A request with a base64 data URI there failed with createTask
  code 500 (cfw order TSW3, 2026-11-05). So each --ref file is first sent to Kie's File
  Upload API (POST https://kieai.redpandaai.co/api/file-stream-upload, multipart
  file + uploadPath + fileName, Bearer key; the hosted URL is data.downloadUrl;
  uploads are free and kept 24 hours - docs.kie.ai/file-upload-api/quickstart).
  --ref is accepted only for a model listed in REF_MODELS, so a reference is never
  sent to a model that would silently ignore it. After the create call, the first
  status reply that carries recordInfo.param must still hold the references in
  input_urls, or the image is refused (Kie drops unknown keys without an error).

Usage
  generate.py --provider kie --aspect 16:9 --prompt "<prompt>" --out work/visuals/img_01.png
              [--model z-image] [--timeout 150] [--poll 5] [--dry-run]
  generate.py --provider kie --model gpt-image-2-image-to-image --aspect 9:16 --resolution 2K
              --ref prior/char_ref.png --prompt "<prompt>" --out work/raw-1.png

Output
  KIE_TASK: <task id>       printed once Kie accepts the create call
  Last line of stdout:
  IMAGE_FILE: <path>        success; the PNG is at <path>
  IMAGE_FAILED: <reason>    failure (exit 1 or 3)
  A bad command line prints its problem on stderr and exits 2.

Exit codes
  0 image saved        1 Kie or network failure, rejected request, timeout, bad download
  2 bad arguments      3 no Kie key in the environment (nothing was sent)

--dry-run checks the arguments, the reference files and the key, prints what it would
send (never the key) and exits 0 without any network call.
"""
import argparse
import hashlib
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
# Kie File Upload API base (docs.kie.ai/file-upload-api/quickstart, "API Base URL").
DEFAULT_UPLOAD_BASE = "https://kieai.redpandaai.co"
UPLOAD_PATH = "cfw-render/refs"
DEFAULT_MODEL = "z-image"
UA = "cfw-render-generate/1.0"
MAX_IMAGE_BYTES = 25 * 1024 * 1024
MAX_REF_BYTES = 10 * 1024 * 1024  # Kie i2i docs: "Max size: 10.0MB" per input file
KEY_NAME = "KIE_AI_API_KEY"
# Models that read reference images from input.input_urls, with the aspect ratios and
# resolutions their Kie doc page allows. Source: docs.kie.ai/market/gpt/gpt-image-2-image-to-image
# (aspect_ratio enum; resolution 1K/2K/4K, "Set this field explicitly"; 2K excludes 5:4, 4:5,
# 3:1, 1:3, 9:21; 4K excludes 3:1, 1:3, 9:21; input_urls max 16).
REF_MODELS = {
    "gpt-image-2-image-to-image": {
        "aspects": ("1:1", "3:2", "2:3", "4:3", "3:4", "5:4", "4:5", "16:9", "9:16",
                    "2:1", "1:2", "3:1", "1:3", "21:9", "9:21"),
        "resolutions": {"1K": (), "2K": ("5:4", "4:5", "3:1", "1:3", "9:21"), "4K": ("3:1", "1:3", "9:21")},
        "max_refs": 16,
    },
}
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


def check_base(url, default=DEFAULT_BASE, flag="--base-url"):
    if url == default:
        return url
    u = urllib.parse.urlparse(url)
    if u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and u.port:
        return url.rstrip("/")
    raise Usage("%s may only be %s (or a local http address for tests)" % (flag, default))


def ref_kind(path):
    """(mime, extension) of a PNG, JPEG or WEBP reference file, or a Usage error."""
    if not os.path.isfile(path):
        raise Usage("--ref %r is not a file" % path)
    size = os.path.getsize(path)
    if not 0 < size <= MAX_REF_BYTES:
        raise Usage("--ref %r must be 1 byte to %d MB" % (path, MAX_REF_BYTES // (1024 * 1024)))
    with open(path, "rb") as fh:
        head = fh.read(16)
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", ".png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg", ".jpg"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", ".webp"
    raise Usage("--ref %r must be a PNG, JPEG or WEBP image (convert it with ffmpeg first)" % path)


def multipart(fields, file_name, content, mime):
    """A multipart/form-data body: the text `fields` plus one `file` part."""
    boundary = "cfw-render-" + os.urandom(16).hex()
    out = []
    for k, v in fields:
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n" % (boundary, k, v)).encode())
    out.append(("--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\nContent-Type: %s\r\n\r\n"
                % (boundary, file_name, mime)).encode())
    out.append(content)
    out.append(("\r\n--%s--\r\n" % boundary).encode())
    return b"".join(out), "multipart/form-data; boundary=" + boundary


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


def http(method, url, key=None, body=None, timeout=30, form=None):
    """Return (status, bytes). Raises Failed on a network problem.
    `body` is sent as JSON; `form` is a (bytes, content_type) pair from multipart()."""
    headers = {"User-Agent": UA, "Accept": "application/json, image/*"}
    data = None
    if key:
        headers["Authorization"] = "Bearer " + key
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data, headers["Content-Type"] = form
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


def upload_ref(upload_base, key, path, local_ok):
    """Send one local reference image to Kie's File Upload API; return its hosted URL.
    Uploads are free (docs.kie.ai/file-upload-api/quickstart), so nothing can be charged twice,
    but a refused upload stops the run: the image would not be anchored on the reference.
    The file name is the content hash, so a repeat upload of the same bytes lands on the same path."""
    mime, ext = ref_kind(path)
    with open(path, "rb") as fh:
        content = fh.read()
    name = hashlib.sha256(content).hexdigest()[:32] + ext
    form = multipart((("uploadPath", UPLOAD_PATH), ("fileName", name)), name, content, mime)
    status, raw = http("POST", upload_base + "/api/file-stream-upload", key, form=form, timeout=60)
    try:
        reply = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        reply = None
    url = ((reply or {}).get("data") or {}).get("downloadUrl") if isinstance(reply, dict) else None
    if status != 200 or not isinstance(reply, dict) or str(reply.get("code")) != "200" or not url:
        raise Failed("Kie did not accept the reference upload of %s: %s; no image was requested"
                     % (os.path.basename(path), api_error(status, raw)))
    u = urllib.parse.urlparse(str(url))
    if u.scheme != "https" and not (local_ok and u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost")):
        raise Failed("Kie's reference upload returned an address that is not https; no image was requested")
    return str(url)


def echoed_refs(param):
    """The input_urls Kie recorded for a task (recordInfo.data.param, a JSON string), [] when
    the recorded input has no input_urls, or None when the shape is not recognised."""
    try:
        p = json.loads(param) if isinstance(param, str) else param
    except ValueError:
        return None
    if not isinstance(p, dict):
        return None
    inp = p.get("input", p)
    if isinstance(inp, str):
        try:
            inp = json.loads(inp)
        except ValueError:
            return None
    if not isinstance(inp, dict):
        return None
    if "input_urls" in inp:
        refs = inp["input_urls"]
        return [str(r) for r in refs] if isinstance(refs, list) else []
    return [] if "prompt" in inp else None


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
    ap.add_argument("--ref", action="append", default=[], metavar="FILE",
                    help="reference image (PNG/JPEG/WEBP, max 10 MB), uploaded to Kie and sent in input_urls; "
                         "repeatable; only for: " + ", ".join(sorted(REF_MODELS)))
    ap.add_argument("--resolution", help="output resolution sent as input.resolution (1K, 2K or 4K)")
    ap.add_argument("--timeout", type=int, default=150, help="seconds to wait for the image (default 150)")
    ap.add_argument("--poll", type=int, default=5, help="seconds between status checks (default 5)")
    ap.add_argument("--base-url", default=DEFAULT_BASE, help=argparse.SUPPRESS)
    ap.add_argument("--upload-base-url", default=DEFAULT_UPLOAD_BASE, help=argparse.SUPPRESS)
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
    if args.resolution is not None and args.resolution not in ("1K", "2K", "4K"):
        raise Usage("--resolution must be 1K, 2K or 4K, got %r" % args.resolution)
    spec = REF_MODELS.get(args.model)
    if args.ref and not spec:
        raise Usage("--ref is only supported for %s; model %s would silently ignore the reference"
                    % (", ".join(sorted(REF_MODELS)), args.model))
    if spec:
        if not args.ref:
            raise Usage("model %s is image-to-image: give at least one --ref" % args.model)
        if len(args.ref) > spec["max_refs"]:
            raise Usage("model %s takes at most %d --ref images" % (args.model, spec["max_refs"]))
        if args.aspect not in spec["aspects"]:
            raise Usage("model %s does not support --aspect %s" % (args.model, args.aspect))
        if args.resolution is None:
            raise Usage("model %s needs --resolution (1K, 2K or 4K; Kie: set it explicitly)" % args.model)
        if args.aspect in spec["resolutions"][args.resolution]:
            raise Usage("model %s does not support --aspect %s at %s" % (args.model, args.aspect, args.resolution))
    for r in args.ref:
        ref_kind(r)
    base = check_base(args.base_url)
    upload_base = check_base(args.upload_base_url, DEFAULT_UPLOAD_BASE, "--upload-base-url")

    key_name, key = find_key()
    if args.dry_run:
        print("DRY RUN: would %screate one %s%s image (%s) with model %s -> %s" % (
            "upload %d reference image(s) to Kie's file upload, send them in input_urls, then " % len(args.ref)
            if args.ref else "", args.aspect, " " + args.resolution if args.resolution else "",
            "key found in " + key_name if key else "NO KEY, it would stop with exit 3", args.model, args.out))
        print("no request was sent")
        return 0
    if not key:
        finish(False, "no Kie key in the environment (set KIE_AI_API_KEY); nothing was sent and nothing was spent", 3)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)

    # 0. Upload the reference images (free). Kie reads input_urls as hosted URLs, never file content.
    test_hosts = upload_base != DEFAULT_UPLOAD_BASE
    ref_urls = [upload_ref(upload_base, key, r, test_hosts) for r in args.ref]

    # 1. Create the task. Exactly once: a retry could be charged twice.
    task_input = {"prompt": prompt, "aspect_ratio": args.aspect}
    if args.resolution:
        task_input["resolution"] = args.resolution
    if ref_urls:
        task_input["input_urls"] = ref_urls
    try:
        status, raw = http("POST", base + "/api/v1/jobs/createTask", key,
                           {"model": args.model, "input": task_input})
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
    print("KIE_TASK: " + task, flush=True)

    # 2. Poll. Status checks are free, so a short network blip is retried.
    deadline = time.time() + args.timeout
    url = None
    blips = 0
    refs_checked = not ref_urls
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
            if not refs_checked and data.get("param") is not None:
                # Kie silently drops an input key it does not read; an i2i task whose recorded
                # input has lost the references would come back as a plain text-to-image.
                echoed = echoed_refs(data.get("param"))
                if echoed is not None and len(echoed) != len(ref_urls):
                    raise Failed("Kie task %s did not keep the reference image(s) in input_urls (recorded %d of %d); "
                                 "the image would not match the reference" % (task, len(echoed), len(ref_urls)))
                if echoed is None:
                    sys.stderr.write("generate.py: recordInfo.param has an unknown shape; reference echo not checked\n")
                refs_checked = True
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
