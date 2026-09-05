#!/usr/bin/env python3
"""mock-server.py — stdlib-only mock of /api/v1/mcp (JSON-RPC, the 4 worker
tools) + /api/v1/render/upload, for test/run-tests.sh. No third-party deps
(http.server + a hand-rolled multipart parser, since `cgi` is deprecated/
removed on newer python3).

Usage: mock-server.py <port> <state-dir> <queue-seed-file>

State written under <state-dir>:
  calls.jsonl    — every tools/call, one JSON object per line
  uploads.jsonl  — every /render/upload request, one JSON object per line
"""
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

# ── Admin fleet-enable surface (mock of cfw-social's master-key admin brands
# route, exercised by cfw-render-fleet.sh). Brands are seeded from the queue's
# brandIds, all renderFleetEnabled=false — the real default. MOCK_MASTER_KEY,
# when set, is the master key the route requires in the `cfw-api-key` header
# (else any non-empty key is accepted, matching a "master key configured"
# server that only checks presence-vs-match).
MASTER_KEY = os.environ.get("MOCK_MASTER_KEY")
BRANDS_FLEET = {o.get("brandId"): False for o in QUEUE if o.get("brandId")}

TOOLS = ["claim_render_order", "append_render_event", "complete_render_order", "block_render_order"]


def log_call(name, args, result_ok):
    CALLS_LOG.write(json.dumps({"tool": name, "args": args, "ok": result_ok}) + "\n")


def rpc_result(payload):
    return {"content": [{"type": "text", "text": json.dumps(payload)}]}


def handle_tool_call(name, args):
    if name == "claim_render_order":
        with LOCK:
            for o in QUEUE:
                if STATUS.get(o["id"], "queued") == "queued":
                    STATUS[o["id"]] = "claimed"
                    CLAIMED[o["id"]] = args["workerId"]
                    log_call(name, args, True)
                    return rpc_result({"order": o}), None
            log_call(name, args, True)
            return rpc_result({"order": None}), None

    if name == "append_render_event":
        order_id = args.get("orderId")
        if CLAIMED.get(order_id) != args.get("workerId"):
            log_call(name, args, False)
            return None, {"code": -32000, "message": "order not claimed by this worker"}
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
        with LOCK:
            STATUS[order_id] = "done"
        log_call(name, args, True)
        return rpc_result({"ok": True, "compositionId": "mock-comp-1", "approvalUrl": "https://mock.cfw.social/approve/mock-comp-1"}), None

    if name == "block_render_order":
        order_id = args.get("orderId")
        if CLAIMED.get(order_id) != args.get("workerId"):
            log_call(name, args, False)
            return None, {"code": -32000, "message": "order not claimed by this worker"}
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
            UPLOADS_LOG.write(json.dumps({"orderId": order_id, "workerId": worker_id, "files": [f["filename"] for f in files]}) + "\n")
            self._send_json({"assets": assets})
            return

        self._send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()
