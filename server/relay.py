#!/usr/bin/env python3
"""
Pigeon relay: a dumb, zero-knowledge mailbox.

Senders POST encrypted blobs into an inbox; the receiver (the menu bar app)
long-polls, downloads and deletes them. A deleted item leaves an empty
"<id>.done" marker (until the TTL) so its sender can ask whether it was
delivered; the relay already sees deliveries, so this reveals nothing new. The relay never sees keys or plaintext:
everything it stores was encrypted on the sending device to the receiver's
public key.

Stdlib only (Python 3.8+). Configuration via environment variables:

  RELAY_ADMIN_SECRET   required; needed once to register a new inbox
  RELAY_DATA_DIR       where blobs live (default ./data)
  RELAY_HOST / RELAY_PORT  bind address (default 127.0.0.1:8787)
  RELAY_MAX_MB         max item size in MB (default 100)
  RELAY_TTL_HOURS      undelivered items are deleted after this (default 72)
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

ADMIN_SECRET = os.environ.get("RELAY_ADMIN_SECRET", "")
DATA_DIR = Path(os.environ.get("RELAY_DATA_DIR", "./data")).resolve()
HOST = os.environ.get("RELAY_HOST", "127.0.0.1")
PORT = int(os.environ.get("RELAY_PORT", "8787"))
MAX_BYTES = int(float(os.environ.get("RELAY_MAX_MB", "100")) * 1024 * 1024)
TTL_SECONDS = int(float(os.environ.get("RELAY_TTL_HOURS", "72")) * 3600)
MAX_ITEMS_PER_INBOX = 500
PUBLIC_DIR = Path(__file__).resolve().parent.parent / "web"

ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
MAGIC = b"WD1"

_lock = threading.Lock()
_cond = threading.Condition(_lock)


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def inbox_dir(inbox_id: str) -> Path:
    return DATA_DIR / "inboxes" / inbox_id


def load_inbox(inbox_id: str):
    if not ID_RE.match(inbox_id or ""):
        return None
    meta = inbox_dir(inbox_id) / "inbox.json"
    try:
        return json.loads(meta.read_text())
    except (FileNotFoundError, ValueError):
        return None


def token_ok(expected_hash: str, presented: str) -> bool:
    if not presented:
        return False
    return hmac.compare_digest(expected_hash, sha256_hex(presented))


def list_items(inbox_id: str):
    items_dir = inbox_dir(inbox_id) / "items"
    out = []
    if items_dir.exists():
        for p in items_dir.iterdir():
            if p.suffix == ".bin":
                st = p.stat()
                out.append({"id": p.stem, "size": st.st_size, "ts": int(st.st_mtime)})
    out.sort(key=lambda x: (x["ts"], x["id"]))
    return out


def sweeper():
    while True:
        cutoff = time.time() - TTL_SECONDS
        root = DATA_DIR / "inboxes"
        if root.exists():
            for p in root.glob("*/items/*"):
                try:
                    if p.stat().st_mtime < cutoff:
                        p.unlink()
                except FileNotFoundError:
                    pass
        time.sleep(600)


class Handler(BaseHTTPRequestHandler):
    server_version = "relay"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    # ---- helpers -------------------------------------------------------
    def log_message(self, fmt, *args):
        # Log method + path shape only; never tokens or bodies.
        path = re.sub(r"/inboxes/[^/]+", "/inboxes/<id>", urlparse(self.path).path)
        print(f"{self.address_string()} {self.command} {path} {args[1] if len(args) > 1 else ''}", flush=True)

    def security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")

    def send_json(self, status, obj, close=False):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if close:
            self.send_header("Connection", "close")
        self.security_headers()
        self.end_headers()
        self.wfile.write(body)

    def fail(self, status, msg):
        # Errors are often sent before the request body has been read. On a
        # kept-alive connection those unread bytes would be parsed as the next
        # request, so always close the connection after an error.
        self.close_connection = True
        self.send_json(status, {"error": msg}, close=True)

    def read_body(self, limit):
        length = self.headers.get("Content-Length")
        if length is None:
            self.fail(HTTPStatus.LENGTH_REQUIRED, "length required")
            return None
        length = int(length)
        if length > limit:
            self.fail(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "too large")
            return None
        return self.rfile.read(length)

    def route(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        # Allow running under a path prefix (e.g. /drop/api/...) behind a proxy.
        if "api" in parts:
            parts = parts[parts.index("api"):]
        return parts

    # ---- static sender page --------------------------------------------
    def serve_static(self):
        path = urlparse(self.path).path
        name = path.rsplit("/", 1)[-1] or "index.html"
        files = {
            "index.html": "text/html; charset=utf-8",
            "app.js": "text/javascript; charset=utf-8",
            "manifest.webmanifest": "application/manifest+json",
            "icon.svg": "image/svg+xml",
            "apple-touch-icon.png": "image/png",
        }
        if name not in files:
            name = "index.html"
        data = (PUBLIC_DIR / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", files[name])
        self.send_header("Content-Length", str(len(data)))
        # The page handles key material, so lock it down hard: no third-party
        # anything, no inline script, no framing.
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; manifest-src 'self'; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
        )
        self.send_header("Strict-Transport-Security", "max-age=31536000")
        self.security_headers()
        self.end_headers()
        self.wfile.write(data)

    # ---- API -----------------------------------------------------------
    def do_GET(self):
        parts = self.route()
        if not parts or parts[0] != "api":
            return self.serve_static()
        if parts == ["api", "health"]:
            return self.send_json(200, {"ok": True, "maxMB": MAX_BYTES // (1024 * 1024)})
        # Delivery receipts for a sender: ?ids=a,b,c -> waiting / delivered (with time) / gone.
        if len(parts) == 4 and parts[1] == "inboxes" and parts[3] == "receipts":
            inbox = load_inbox(parts[2])
            if not inbox or not token_ok(inbox["sendHash"], self.headers.get("X-Send-Token", "")):
                time.sleep(0.5)
                return self.fail(HTTPStatus.NOT_FOUND, "not found")
            ids = parse_qs(urlparse(self.path).query).get("ids", [""])[0].split(",")
            ids = [i for i in ids if ID_RE.match(i)][:200]
            items_dir = inbox_dir(parts[2]) / "items"
            receipts = {}
            for i in ids:
                done = items_dir / f"{i}.done"
                if (items_dir / f"{i}.bin").exists():
                    receipts[i] = {"state": "waiting"}
                elif done.exists():
                    receipts[i] = {"state": "delivered", "at": int(done.stat().st_mtime)}
                else:
                    receipts[i] = {"state": "gone"}  # expired, or delivered before receipts existed
            return self.send_json(200, {"receipts": receipts, "ttlHours": TTL_SECONDS / 3600})
        if len(parts) >= 4 and parts[1] == "inboxes" and parts[3] == "items":
            inbox = load_inbox(parts[2])
            if not inbox or not token_ok(inbox["recvHash"], self.headers.get("X-Recv-Token", "")):
                return self.fail(HTTPStatus.NOT_FOUND, "not found")
            if len(parts) == 4:
                q = parse_qs(urlparse(self.path).query)
                wait = min(max(int(q.get("wait", ["0"])[0] or 0), 0), 30)
                deadline = time.time() + wait
                with _cond:
                    items = list_items(parts[2])
                    while not items and time.time() < deadline:
                        _cond.wait(timeout=deadline - time.time())
                        items = list_items(parts[2])
                return self.send_json(200, {"items": items})
            if len(parts) == 5 and ID_RE.match(parts[4]):
                p = inbox_dir(parts[2]) / "items" / f"{parts[4]}.bin"
                if not p.exists():
                    return self.fail(HTTPStatus.NOT_FOUND, "not found")
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(p.stat().st_size))
                self.security_headers()
                self.end_headers()
                with p.open("rb") as f:
                    shutil.copyfileobj(f, self.wfile)
                return
        self.fail(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self):
        parts = self.route()
        # Register a new inbox (receiver does this once, with the admin secret).
        if parts == ["api", "inboxes"]:
            auth = self.headers.get("Authorization", "")
            if not ADMIN_SECRET or not hmac.compare_digest(auth, f"Bearer {ADMIN_SECRET}"):
                time.sleep(1)
                return self.fail(HTTPStatus.UNAUTHORIZED, "unauthorized")
            body = self.read_body(4096)
            if body is None:
                return
            try:
                req = json.loads(body)
                inbox_id, send_hash, recv_hash = req["id"], req["sendHash"], req["recvHash"]
            except (ValueError, KeyError, TypeError):
                return self.fail(HTTPStatus.BAD_REQUEST, "bad request")
            if not ID_RE.match(inbox_id) or not HEX64_RE.match(send_hash) or not HEX64_RE.match(recv_hash):
                return self.fail(HTTPStatus.BAD_REQUEST, "bad request")
            d = inbox_dir(inbox_id)
            (d / "items").mkdir(parents=True, exist_ok=True)
            (d / "inbox.json").write_text(json.dumps({"sendHash": send_hash, "recvHash": recv_hash, "created": int(time.time())}))
            return self.send_json(201, {"ok": True})

        # Drop an encrypted item into an inbox.
        if len(parts) == 4 and parts[1] == "inboxes" and parts[3] == "items":
            inbox = load_inbox(parts[2])
            if not inbox or not token_ok(inbox["sendHash"], self.headers.get("X-Send-Token", "")):
                time.sleep(0.5)
                return self.fail(HTTPStatus.NOT_FOUND, "not found")
            if len(list_items(parts[2])) >= MAX_ITEMS_PER_INBOX:
                return self.fail(HTTPStatus.TOO_MANY_REQUESTS, "inbox full")
            body = self.read_body(MAX_BYTES)
            if body is None:
                return
            if not body.startswith(MAGIC) or len(body) < 3 + 65 + 12 + 16:
                return self.fail(HTTPStatus.BAD_REQUEST, "not an encrypted envelope")
            item_id = f"{int(time.time() * 1000):013d}-{secrets.token_hex(8)}"
            items_dir = inbox_dir(parts[2]) / "items"
            tmp = items_dir / f"{item_id}.tmp"
            tmp.write_bytes(body)
            tmp.rename(items_dir / f"{item_id}.bin")
            with _cond:
                _cond.notify_all()
            return self.send_json(201, {"id": item_id})
        self.fail(HTTPStatus.NOT_FOUND, "not found")

    def do_DELETE(self):
        parts = self.route()
        if len(parts) == 5 and parts[1] == "inboxes" and parts[3] == "items" and ID_RE.match(parts[4]):
            inbox = load_inbox(parts[2])
            if not inbox or not token_ok(inbox["recvHash"], self.headers.get("X-Recv-Token", "")):
                return self.fail(HTTPStatus.NOT_FOUND, "not found")
            items_dir = inbox_dir(parts[2]) / "items"
            try:
                (items_dir / f"{parts[4]}.bin").unlink()
                (items_dir / f"{parts[4]}.done").touch()  # delivery receipt; swept after the TTL
            except FileNotFoundError:
                pass
            return self.send_json(200, {"ok": True})
        self.fail(HTTPStatus.NOT_FOUND, "not found")


def main():
    if len(ADMIN_SECRET) < 16:
        raise SystemExit("Set RELAY_ADMIN_SECRET to a long random value (e.g. `openssl rand -hex 32`).")
    (DATA_DIR / "inboxes").mkdir(parents=True, exist_ok=True)
    threading.Thread(target=sweeper, daemon=True).start()
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    print(f"relay listening on http://{HOST}:{PORT}  data={DATA_DIR}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
