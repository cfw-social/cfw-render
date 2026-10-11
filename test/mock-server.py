#!/usr/bin/env python3
"""mock-server.py — stdlib-only mock of /api/v1/mcp (JSON-RPC, the 4 worker
tools) + the render-output upload surface, for test/run-tests.sh. No
third-party deps (http.server + a hand-rolled multipart parser, since `cgi`
is deprecated/removed on newer python3).

Upload surface (CFW-144 — mirrors cfw-social + the Vercel platform):
  POST /api/v1/render/upload            multipart (legacy). Bodies > 4.5 MB get the
                                        platform's 413 FUNCTION_PAYLOAD_TOO_LARGE.
  POST /api/v1/render/upload-url        JSON presign → {uploadUrl (→ PUT /mock-r2/<key>
                                        on this server), storageKey, cdnUrl, expiresAt, …}
  PUT  /mock-r2/<key>                   the fake bucket: stores byte count + Content-Type,
                                        answers ETag = MD5 of the body (as R2 does)
  POST /api/v1/render/upload-complete   HEAD-equivalent: key must be namespaced under
                                        the claimed order, must have been PUT, bytes/mime
                                        must match → {assets:[{cdnUrl, mimeType, storageKey, bytes}]}

Usage: mock-server.py <port> <state-dir> <queue-seed-file>

State written under <state-dir>:
  calls.jsonl    — every tools/call, one JSON object per line
  uploads.jsonl  — every completed upload, one JSON object per line:
                   {orderId, workerId, files:[name], via: "multipart"|"presign", bytes, puts}
                   (puts = PUT attempts for that key; 1 ⇒ the worker's ETag/MD5 check passed first try)
"""
import hashlib
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
STATE_DIR = sys.argv[2]
QUEUE_SEED = sys.argv[3]

os.makedirs(STATE_DIR, exist_ok=True)
CALLS_LOG = open(os.path.join(STATE_DIR, "calls.jsonl"), "a", buffering=1)
UPLOADS_LOG = open(os.path.join(STATE_DIR, "uploads.jsonl"), "a", buffering=1)
LOCK = threading.Lock()

with open(QUEUE_SEED) as f:
    QUEUE = json.load(f)  # list of order dicts, consumed FIFO
ORDERS_BY_ID = {o["id"]: o for o in QUEUE}
CLAIMED = {}   # orderId -> workerId
STATUS = {}    # orderId -> queued|claimed|done|blocked
PRESIGNS = {}  # storageKey -> {orderId, workerId, filename, mimeType, bytes}
R2_OBJECTS = {}  # storageKey -> {bytes, contentType, md5, puts}
VERCEL_BODY_CAP = 4_500_000  # the platform's request-body cap on Vercel Functions
PRESIGN_MIMES = ("image/jpeg", "image/png", "image/gif", "image/webp",
                 "video/mp4", "video/quicktime", "video/webm", "video/x-m4v", "application/pdf",
                 # M1: json/text step saves (cfw-social presigns them as the `data` kind)
                 "application/json", "text/markdown", "text/plain")

# ── Admin fleet-enable surface (mock of cfw-social's master-key admin brands
# route, exercised by cfw-render-fleet.sh). Brands are seeded from the queue's
# brandIds, all renderFleetEnabled=false — the real default. MOCK_MASTER_KEY,
# when set, is the master key the route requires in the `cfw-api-key` header
# (else any non-empty key is accepted, matching a "master key configured"
# server that only checks presence-vs-match).
MASTER_KEY = os.environ.get("MOCK_MASTER_KEY")
BRANDS_FLEET = {o.get("brandId"): False for o in QUEUE if o.get("brandId")}

TOOLS = ["claim_render_order", "append_render_event", "complete_render_order", "block_render_order", "report_render_step"]

# ── M1-08 step harness surface ────────────────────────────────────────────────
# Orders carrying `recipeVersion` are manifest-driven: the fixture may name a
# manifest JSON path in `manifest` (else env CFW_MOCK_MANIFEST). Such an order
# is claimable ONLY when claim.capabilities.manifests lists its recipe +
# recipeVersion. Control-file interface (all under $CFW_MOCK_CONTROL_DIR):
#   directive        content continue|pause|cancel — read on every report
#   down             exists ⇒ every HTTP request answers 503
#   reports.ndjson   every report_render_step request, one JSON per line
# CFW_MOCK_ASKS=1 ⇒ needs_input is accepted (directive pause) instead of
# answering not_implemented.
CONTROL_DIR = os.environ.get("CFW_MOCK_CONTROL_DIR") or os.path.join(STATE_DIR, "control")
os.makedirs(CONTROL_DIR, exist_ok=True)
REPORTS_LOG = open(os.path.join(CONTROL_DIR, "reports.ndjson"), "a", buffering=1)
MOCK_ASKS = os.environ.get("CFW_MOCK_ASKS") == "1"
ATTEMPTS = {}   # orderId -> {"id", "number", "lastSeq", "seen": set()}
OUTPUT_HOSTS = ("media.cfw.social", "media.mock.cfw.social", "cfw-media.test", "localhost")
STEP_EVENTS = ("step_started", "step_completed", "step_skipped", "step_failed", "needs_input",
               "heartbeat", "attempt_completed", "attempt_failed", "attempt_cancelled")


def mock_down():
    return os.path.exists(os.path.join(CONTROL_DIR, "down"))


def scripted_directive(default):
    try:
        with open(os.path.join(CONTROL_DIR, "directive")) as fh:
            val = fh.read().strip()
    except OSError:
        return default
    return val if val in ("continue", "pause", "cancel") else default


def load_manifest(order):
    path = order.get("manifest") or os.environ.get("CFW_MOCK_MANIFEST")
    if isinstance(path, dict):
        return path
    if not path:
        return None
    with open(path) as fh:
        return json.load(fh)


def capability_matches(order, capabilities):
    if not isinstance(capabilities, dict):
        return False
    for m in capabilities.get("manifests") or []:
        if isinstance(m, dict) and m.get("recipe") == order.get("recipe") \
                and m.get("recipeVersion") == order.get("recipeVersion"):
            return True
    return False


def manifest_order_payload(order):
    manifest = load_manifest(order) or {}
    steps = manifest.get("steps") or []
    resume = next((s["id"] for s in steps if s.get("runsOn") == "computer"), None)
    attempt = {"id": "att_1", "number": 1}
    ATTEMPTS[order["id"]] = {"id": attempt["id"], "number": 1, "lastSeq": 0, "seen": set(),
                            "stepIds": {s["id"] for s in steps}}
    out = dict(order)
    out.update({"attempt": attempt, "manifest": manifest, "resumeFromStepId": resume,
                "savedOutputs": [],
                # the fixture may seed inputs/answers (M1-03 fills them for real)
                "inputs": order.get("inputs") or {}, "answers": order.get("answers") or {}})
    return out


def step_reply(ok, code=None, error=None, directive="continue", duplicate=False):
    payload = {"ok": ok, "duplicate": duplicate, "directive": directive}
    if code is not None:
        payload["code"] = code
    if error is not None:
        payload["error"] = error
    return payload


def record_report(args, reply):
    # Every non-duplicate arrival (accepted or rejected) lands in reports.ndjson
    # in arrival order; a duplicate seq stores nothing, per the contract.
    if not reply.get("duplicate"):
        REPORTS_LOG.write(json.dumps({**args, "_reply": reply}) + "\n")


def handle_report_step(args):
    order_id = args.get("orderId")
    if CLAIMED.get(order_id) != args.get("workerId"):
        return step_reply(False, "order_not_held", "order not held by this worker", "cancel")
    att = ATTEMPTS.get(order_id)
    if att is None or args.get("attemptId") != att["id"]:
        return step_reply(False, "attempt_superseded", "attempt is not current", "cancel")
    event = args.get("event")
    if event not in STEP_EVENTS:
        return step_reply(False, "bad_event", f"unknown event {event!r}", scripted_directive("continue"))
    seq = args.get("seq")
    if not isinstance(seq, int):
        return step_reply(False, "bad_seq", "seq must be an integer", scripted_directive("continue"))
    with LOCK:
        if seq in att["seen"]:
            return step_reply(True, directive=scripted_directive("continue"), duplicate=True)
        if seq < att["lastSeq"]:
            return step_reply(False, "seq_out_of_order", f"seq {seq} < last {att['lastSeq']}",
                              scripted_directive("continue"))
        step_id = args.get("stepId")
        if step_id is not None and step_id not in att["stepIds"]:
            return step_reply(False, "unknown_step", f"step {step_id!r} not in manifest",
                              scripted_directive("continue"))
        for o in args.get("outputs") or []:
            host = (o.get("url", "").split("://", 1)[-1].split("/", 1)[0].split(":", 1)[0]) if isinstance(o, dict) else ""
            if host not in OUTPUT_HOSTS:
                return step_reply(False, "invalid_output_url", f"output url host {host!r} not allowed",
                                  scripted_directive("continue"))
        if event == "needs_input" and not MOCK_ASKS:
            return step_reply(False, "not_implemented", "asks not implemented", "pause")
        att["seen"].add(seq)
        att["lastSeq"] = seq
    default = "pause" if event == "needs_input" else "continue"
    return step_reply(True, directive=scripted_directive(default))


def log_call(name, args, result_ok):
    CALLS_LOG.write(json.dumps({"tool": name, "args": args, "ok": result_ok}) + "\n")


def rpc_result(payload):
    return {"content": [{"type": "text", "text": json.dumps(payload)}]}


def handle_tool_call(name, args):
    if name == "claim_render_order":
        # CFW-146: the renderer identity is optional but must be well-formed
        # when present (the owner card reads its `kind`).
        r = args.get("renderer")
        if r is not None and (not isinstance(r, dict) or r.get("kind") not in ("mac", "box", "byo", "fleet")):
            log_call(name, args, False)
            return rpc_result({"order": None, "error": "bad renderer identity"}), None
        with LOCK:
            for o in QUEUE:
                if STATUS.get(o["id"], "queued") == "queued":
                    # M1-08: manifest-driven orders need a matching capability.
                    if o.get("recipeVersion") is not None:
                        if not capability_matches(o, args.get("capabilities")):
                            continue
                        STATUS[o["id"]] = "claimed"
                        CLAIMED[o["id"]] = args["workerId"]
                        log_call(name, args, True)
                        return rpc_result({"order": manifest_order_payload(o)}), None
                    STATUS[o["id"]] = "claimed"
                    CLAIMED[o["id"]] = args["workerId"]
                    log_call(name, args, True)
                    return rpc_result({"order": o}), None
            log_call(name, args, True)
            return rpc_result({"order": None}), None

    if name == "report_render_step":
        reply = handle_report_step(args)
        record_report(args, reply)
        log_call(name, args, bool(reply.get("ok")))
        return rpc_result(reply), None

    if name == "append_render_event":
        order_id = args.get("orderId")
        if CLAIMED.get(order_id) != args.get("workerId"):
            log_call(name, args, False)
            return None, {"code": -32000, "message": "order not claimed by this worker"}
        # CFW-146: a heartbeat is a pulse, not progress — it may carry the
        # renderer kind on `stage` but never a pct, and it never lands on a
        # terminal order (the drainer stops the pulse before reporting).
        if args.get("kind") == "heartbeat":
            if STATUS.get(order_id) in ("done", "blocked"):
                log_call(name, args, False)
                return None, {"code": -32000, "message": "order is terminal"}
            if args.get("pct") is not None:
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": "heartbeat must not carry pct"}), None
            stage = args.get("stage")
            if stage is not None and stage not in ("mac", "box", "byo", "fleet"):
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": f"bad renderer kind {stage!r}"}), None
        log_call(name, args, True)
        return rpc_result({"ok": True}), None

    if name == "complete_render_order":
        order_id = args.get("orderId")
        if CLAIMED.get(order_id) != args.get("workerId"):
            log_call(name, args, False)
            return None, {"code": -32000, "message": "order not claimed by this worker"}
        order = ORDERS_BY_ID.get(order_id, {})
        brand_id = order.get("brandId", "")
        expected = f"brands/{brand_id}/renders/{order_id}/"
        # CFW-135: same precedence as cfw-social — outputs[] > outputUrls[] > outputUrl.
        if args.get("outputs"):
            urls = [o.get("url", "") for o in args["outputs"]]
        elif args.get("outputUrls"):
            urls = list(args["outputUrls"])
        else:
            urls = [args.get("outputUrl", "")]
        if not urls or any(expected not in u for u in urls):
            log_call(name, args, False)
            return rpc_result({"ok": False, "error": "outputUrl not brand/order-namespaced"}), None
        # A PDF must be typed `doc` (never a slide) — mirrors the server-side inference.
        for o in args.get("outputs") or []:
            if o.get("url", "").lower().endswith(".pdf") and o.get("kind") != "doc":
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": "pdf output must be kind doc"}), None
        # CFW-136: captions, when sent, must be a {platform: non-blank string} map
        # (the report script drops blanks — a blank reaching here is a regression);
        # outputs[].role must be one of cover|slide|poster; on a video order the
        # image that follows the video must be the poster (never a slide).
        caps = args.get("captions")
        if caps is not None:
            if not isinstance(caps, dict) or not caps:
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": "captions must be a non-empty object"}), None
            for k, v in caps.items():
                if not isinstance(k, str) or not k or k != k.lower() or not isinstance(v, str) or not v.strip():
                    log_call(name, args, False)
                    return rpc_result({"ok": False, "error": f"captions[{k!r}] must be a lower-cased key with a non-blank caption"}), None
        seen_video = False
        for o in args.get("outputs") or []:
            role = o.get("role")
            if role is not None and role not in ("cover", "slide", "poster"):
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": f"bad role {role!r}"}), None
            if o.get("kind") == "video":
                seen_video = True
            elif o.get("kind") == "image" and seen_video and role == "slide":
                log_call(name, args, False)
                return rpc_result({"ok": False, "error": "image after a video must be role poster"}), None
        with LOCK:
            STATUS[order_id] = "done"
        log_call(name, args, True)
        return rpc_result({"ok": True, "compositionId": "mock-comp-1", "approvalUrl": "https://mock.cfw.social/approve/mock-comp-1"}), None

    if name == "block_render_order":
        order_id = args.get("orderId")
        if CLAIMED.get(order_id) != args.get("workerId"):
            log_call(name, args, False)
            return None, {"code": -32000, "message": "order not claimed by this worker"}
        # CFW-146: `needs` is optional, but only the three contract values.
        if args.get("needs") is not None and args["needs"] not in ("ingredient", "decision", "capacity"):
            log_call(name, args, False)
            return rpc_result({"ok": False, "error": f"bad needs {args['needs']!r}"}), None
        with LOCK:
            STATUS[order_id] = "blocked"
        log_call(name, args, True)
        return rpc_result({"ok": True}), None

    # Unimplemented tool (e.g. requeue_render_order) — mirrors the real gap
    # (implementation-plan.md §0.4): the server genuinely has no such tool.
    log_call(name, args, False)
    return None, {"code": -32601, "message": f"Unknown tool: {name}"}


def parse_multipart(body: bytes, boundary: bytes):
    parts = body.split(b"--" + boundary)
    fields = {}
    files = []
    for part in parts:
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        header_blob, content = part.split(b"\r\n\r\n", 1)
        content = content.rstrip(b"\r\n")
        headers = {}
        for line in header_blob.split(b"\r\n"):
            if b":" in line:
                k, v = line.split(b":", 1)
                headers[k.strip().lower().decode()] = v.strip().decode()
        disp = headers.get("content-disposition", "")
        name = None
        filename = None
        for token in disp.split(";"):
            token = token.strip()
            if token.startswith("name="):
                name = token[5:].strip('"')
            elif token.startswith("filename="):
                filename = token[9:].strip('"')
        if filename is not None:
            files.append({"field": name, "filename": filename, "content": content,
                          "mime": headers.get("content-type", "application/octet-stream")})
        elif name is not None:
            fields[name] = content.decode(errors="replace")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # keep test output clean

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _admin_denied(self):
        """Return True (and send 401) unless the master key is presented.
        Mirrors cfw-social assertMasterOrAdmin() for the master-key path."""
        key = self.headers.get("cfw-api-key", "")
        if not key:
            self._send_json({"error": "Not found"}, 404)
            return True
        if MASTER_KEY is not None and key != MASTER_KEY:
            self._send_json({"error": "Invalid master API key"}, 401)
            return True
        return False

    def _admin_brand_id(self):
        """/api/v1/admin/brands/<id> -> <id>, else None."""
        prefix = "/api/v1/admin/brands/"
        if self.path.startswith(prefix):
            rest = self.path[len(prefix):]
            return rest.split("?", 1)[0].split("/", 1)[0] or None
        return None

    def handle_one_request(self):
        # M1-08 unreachable switch: $CFW_MOCK_CONTROL_DIR/down ⇒ 503 for everything.
        if not mock_down():
            return BaseHTTPRequestHandler.handle_one_request(self)
        self.raw_requestline = self.rfile.readline(65537)
        if not self.raw_requestline:
            self.close_connection = True
            return
        if not self.parse_request():
            return
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)
        self._send_json({"error": "mock down"}, 503)

    def do_GET(self):
        brand_id = self._admin_brand_id()
        if brand_id is not None:
            if self._admin_denied():
                return
            if brand_id not in BRANDS_FLEET:
                self._send_json({"error": "not_found"}, 404)
                return
            self._send_json({"id": brand_id, "renderFleetEnabled": BRANDS_FLEET[brand_id]})
            return
        # Any other GET (e.g. the test harness's /api/v1/mcp reachability probe)
        # just needs to answer so the socket is proven live.
        self._send_json({"error": "not found"}, 404)

    def do_PATCH(self):
        brand_id = self._admin_brand_id()
        if brand_id is None:
            self._send_json({"error": "not found"}, 404)
            return
        if self._admin_denied():
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw)
        except Exception:
            self._send_json({"error": "Invalid JSON"}, 400)
            return
        if "renderFleetEnabled" not in body or not isinstance(body["renderFleetEnabled"], bool):
            self._send_json({"error": "Expected { renderFleetEnabled: boolean }"}, 422)
            return
        if brand_id not in BRANDS_FLEET:
            self._send_json({"error": "not_found"}, 404)
            return
        with LOCK:
            BRANDS_FLEET[brand_id] = body["renderFleetEnabled"]
        self._send_json({"ok": True, "id": brand_id, "renderFleetEnabled": BRANDS_FLEET[brand_id]})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""

        if self.path == "/api/v1/mcp":
            key = self.headers.get("cfw-render-key", "")
            if not key:
                self._send_json({"error": "missing cfw-render-key"}, 401)
                return
            try:
                req = json.loads(raw)
            except Exception:
                self._send_json({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
                return
            method = req.get("method")
            rid = req.get("id")
            if method == "tools/list":
                self._send_json({"jsonrpc": "2.0", "id": rid, "result": {"tools": [{"name": t} for t in TOOLS]}})
                return
            if method == "tools/call":
                params = req.get("params", {})
                name = params.get("name")
                args = params.get("arguments", {})
                result, error = handle_tool_call(name, args)
                if error:
                    self._send_json({"jsonrpc": "2.0", "id": rid, "error": error})
                else:
                    self._send_json({"jsonrpc": "2.0", "id": rid, "result": result})
                return
            self._send_json({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "method not found"}})
            return

        if self.path == "/api/v1/render/upload":
            # Vercel Functions reject the body BEFORE the function runs (CFW-144).
            if length > VERCEL_BODY_CAP:
                body = b"Request Entity Too Large\n\nFUNCTION_PAYLOAD_TOO_LARGE\n"
                self.send_response(413)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            key = self.headers.get("cfw-render-key", "")
            if not key:
                self._send_json({"error": "missing cfw-render-key"}, 401)
                return
            ctype = self.headers.get("Content-Type", "")
            if "boundary=" not in ctype:
                self._send_json({"error": "no boundary"}, 400)
                return
            boundary = ctype.split("boundary=", 1)[1].strip().encode()
            fields, files = parse_multipart(raw, boundary)
            order_id = fields.get("orderId")
            worker_id = fields.get("workerId")
            if not order_id or not worker_id or not files:
                self._send_json({"error": "orderId, workerId and files are required"}, 400)
                return
            order = ORDERS_BY_ID.get(order_id, {})
            brand_id = order.get("brandId", "unknown-brand")
            assets = []
            for i, fi in enumerate(files):
                cdn_url = f"https://media.mock.cfw.social/brands/{brand_id}/renders/{order_id}/{i}-{fi['filename']}"
                assets.append({"cdnUrl": cdn_url, "mimeType": fi["mime"]})
            UPLOADS_LOG.write(json.dumps({"orderId": order_id, "workerId": worker_id, "files": [f["filename"] for f in files],
                                          "via": "multipart", "bytes": sum(len(f["content"]) for f in files)}) + "\n")
            self._send_json({"assets": assets})
            return

        if self.path in ("/api/v1/render/upload-url", "/api/v1/render/upload-complete"):
            key = self.headers.get("cfw-render-key", "")
            if not key:
                self._send_json({"error": "Invalid render worker key"}, 401)
                return
            try:
                req = json.loads(raw)
            except Exception:
                self._send_json({"error": "Invalid JSON body"}, 400)
                return
            order_id = req.get("orderId"); worker_id = req.get("workerId")
            if not order_id or not worker_id:
                self._send_json({"error": "orderId and workerId are required"}, 400)
                return
            if CLAIMED.get(order_id) != worker_id or STATUS.get(order_id) not in ("claimed",):
                self._send_json({"error": "Order not claimed by this worker"}, 403)
                return
            order = ORDERS_BY_ID.get(order_id, {})
            brand_id = order.get("brandId", "unknown-brand")
            namespace = f"brands/{brand_id}/renders/{order_id}/"
            if self.path == "/api/v1/render/upload-url":
                filename = req.get("filename"); mime = (req.get("mimeType") or "").lower(); nbytes = req.get("bytes")
                if not filename or not mime or not isinstance(nbytes, int) or nbytes <= 0:
                    self._send_json({"error": "filename, mimeType and bytes are required"}, 400)
                    return
                if mime not in PRESIGN_MIMES:
                    self._send_json({"error": f"Unsupported mime {mime!r}", "code": "unsupported_type"}, 400)
                    return
                storage_key = f"{namespace}{len(PRESIGNS):06x}-{os.path.basename(filename).lower()}"
                PRESIGNS[storage_key] = {"orderId": order_id, "workerId": worker_id, "filename": filename, "mimeType": mime, "bytes": nbytes}
                self._send_json({
                    "uploadUrl": f"http://127.0.0.1:{PORT}/mock-r2/{storage_key}?sig=mock",
                    "storageKey": storage_key,
                    "cdnUrl": f"https://media.mock.cfw.social/{storage_key}",
                    "mimeType": mime,
                    "expiresAt": "2099-01-01T00:00:00.000Z",
                    "expiresInSec": 900,
                    "maxBytes": 2 * 1024 * 1024 * 1024,
                })
                return
            # upload-complete
            storage_key = req.get("storageKey") or ""
            if not storage_key.startswith(namespace) or "/" in storage_key[len(namespace):] or ".." in storage_key:
                self._send_json({"error": f"storageKey must be brand-namespaced under {namespace}", "code": "out_of_namespace"}, 403)
                return
            obj = R2_OBJECTS.get(storage_key)
            if not obj:
                self._send_json({"error": "Object not found on CFW Media", "code": "not_uploaded"}, 404)
                return
            if isinstance(req.get("bytes"), int) and req["bytes"] != obj["bytes"]:
                self._send_json({"error": "size mismatch", "code": "size_mismatch"}, 409)
                return
            if req.get("mimeType") and req["mimeType"].lower() != obj["contentType"]:
                self._send_json({"error": "mime mismatch", "code": "mime_mismatch"}, 409)
                return
            pre = PRESIGNS.get(storage_key, {})
            UPLOADS_LOG.write(json.dumps({"orderId": order_id, "workerId": worker_id, "files": [pre.get("filename", storage_key)],
                                          "via": "presign", "bytes": obj["bytes"], "puts": obj["puts"]}) + "\n")
            self._send_json({"assets": [{"cdnUrl": f"https://media.mock.cfw.social/{storage_key}", "mimeType": obj["contentType"],
                                         "storageKey": storage_key, "bytes": obj["bytes"]}]})
            return

        self._send_json({"error": "not found"}, 404)

    def do_PUT(self):
        # The fake R2 bucket. Only keys that were presigned are accepted (a real
        # presigned URL is bound to one key + Content-Type).
        path = self.path.split("?", 1)[0]
        if not path.startswith("/mock-r2/"):
            self._send_json({"error": "not found"}, 404)
            return
        storage_key = path[len("/mock-r2/"):]
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        ctype = (self.headers.get("Content-Type") or "").lower()
        pre = PRESIGNS.get(storage_key)
        if not pre or pre["mimeType"] != ctype:
            self._send_json({"error": "SignatureDoesNotMatch"}, 403)
            return
        digest = hashlib.md5(raw).hexdigest()
        with LOCK:
            puts = R2_OBJECTS.get(storage_key, {}).get("puts", 0) + 1
            R2_OBJECTS[storage_key] = {"bytes": len(raw), "contentType": ctype, "md5": digest, "puts": puts}
        self.send_response(200)
        self.send_header("ETag", f'"{digest}"')
        self.send_header("Content-Length", "0")
        self.end_headers()


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()
