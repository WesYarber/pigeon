#!/usr/bin/env python3
"""
A headless stand-in for a Mac, for demos and App Review: it owns one inbox on
your relay, accepts whatever is sent to it, checks that it decrypts, logs only
the kind and size (never names or contents), and throws it away. The sender
then sees "Delivered".

  pip install cryptography        # or: apt install python3-cryptography
  RELAY_URL=https://relay.example.com RELAY_ADMIN_SECRET=... \
  PIGEON_DEMO_STATE=/var/lib/pigeon-demo/state.json python3 demo_receiver.py

On first run it registers a new inbox (the only time the admin secret is
used), saves its key and tokens to the state file (mode 600) and prints the
pairing link. Later runs reuse the state file; `--link` prints the link again.
"""
import base64
import hashlib
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"WD1"
INFO = b"pigeon v1"
RELAY = os.environ.get("RELAY_URL", "").rstrip("/")
STATE = Path(os.environ.get("PIGEON_DEMO_STATE", "./demo-state.json"))


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def log(msg: str):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def request(method, path, headers=None, body=None, timeout=40):
    req = urllib.request.Request(RELAY + path, data=body, method=method, headers=headers or {})
    req.add_header("User-Agent", "pigeon-demo-receiver")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def public_bytes(key) -> bytes:
    return key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)


def load_or_register():
    if STATE.exists():
        s = json.loads(STATE.read_text())
        key = serialization.load_pem_private_key(s["key"].encode(), password=None)
        return s, key
    secret = os.environ.get("RELAY_ADMIN_SECRET", "").strip()
    if not RELAY or not secret:
        sys.exit("First run needs RELAY_URL and RELAY_ADMIN_SECRET to register an inbox.")
    key = ec.generate_private_key(ec.SECP256R1())
    s = {
        "relay": RELAY,
        "inbox": b64url(secrets.token_bytes(16)),
        "sendToken": b64url(secrets.token_bytes(32)),
        "recvToken": b64url(secrets.token_bytes(32)),
        "key": key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption()).decode(),
    }
    body = json.dumps({"id": s["inbox"],
                       "sendHash": hashlib.sha256(s["sendToken"].encode()).hexdigest(),
                       "recvHash": hashlib.sha256(s["recvToken"].encode()).hexdigest()}).encode()
    request("POST", "/api/inboxes", {"Authorization": f"Bearer {secret}", "Content-Type": "application/json"}, body)
    STATE.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(STATE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(s, f)
    log(f"registered inbox; pairing link:\n{pairing_link(s, key)}")
    return s, key


def pairing_link(s, key) -> str:
    return f"{s['relay'].rstrip('/')}/#p=v1.{s['inbox']}.{s['sendToken']}.{b64url(public_bytes(key))}"


def open_envelope(env: bytes, key) -> dict:
    if len(env) < 3 + 65 + 12 + 16 or env[:3] != MAGIC:
        raise ValueError("not an envelope")
    eph = env[3:68]
    iv, ct = env[68:80], env[80:]
    shared = key.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), eph))
    sym = HKDF(algorithm=hashes.SHA256(), length=32, salt=eph + public_bytes(key), info=INFO).derive(shared)
    pt = AESGCM(sym).decrypt(iv, ct, MAGIC + eph)
    hlen = int.from_bytes(pt[:4], "big")
    header = json.loads(pt[4:4 + hlen])
    header["_size"] = len(pt) - 4 - hlen
    return header


def main():
    global RELAY
    s, key = load_or_register()
    RELAY = s["relay"].rstrip("/")
    if "--link" in sys.argv:
        return print(pairing_link(s, key))
    auth = {"X-Recv-Token": s["recvToken"]}
    base = f"/api/inboxes/{s['inbox']}/items"
    log(f"waiting for items on {RELAY}")
    while True:
        try:
            items = json.loads(request("GET", f"{base}?wait=25", auth))["items"]
            for item in items:
                iid = item["id"] if isinstance(item, dict) else item
                try:
                    h = open_envelope(request("GET", f"{base}/{iid}", auth, timeout=120), key)
                    log(f"received {h.get('kind', '?')} ({h['_size']} bytes), discarded")
                except Exception as e:  # still delete it, so the inbox never fills up
                    log(f"received an item that didn't open ({type(e).__name__}), discarded")
                request("DELETE", f"{base}/{iid}", auth)
        except urllib.error.HTTPError as e:
            log(f"relay said HTTP {e.code}")
            time.sleep(30)
        except Exception as e:
            log(f"relay unreachable ({type(e).__name__}), retrying")
            time.sleep(15)


if __name__ == "__main__":
    main()
