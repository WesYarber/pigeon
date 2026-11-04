#!/usr/bin/env python3
"""
Builds the self-contained hand-off files from the current source tree:

  server-setup-prompt.md   fresh relay install (for an agent on the home server)
  server-update-prompt.md  update an existing relay to the current files
  other-mac-setup.md       build + install the Mac app on another Mac

Every embedded file is checked to round-trip byte-for-byte. Run from the repo root.
"""
import base64
import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Your relay's address goes in tools/relay-host.txt (gitignored) or $PIGEON_RELAY_HOST,
# so it never ends up in the repository.
_host_file = ROOT / "tools/relay-host.txt"
HOST = (os.environ.get("PIGEON_RELAY_HOST")
        or (_host_file.read_text().strip() if _host_file.exists() else "")
        or "relay.example.com")
DOMAIN = HOST.split(".", 1)[1] if HOST.count(".") >= 2 else HOST
LANG = {".py": "python", ".html": "html", ".js": "javascript", ".webmanifest": "json", ".svg": "xml",
        ".yml": "yaml", ".swift": "swift", ".sh": "bash"}

SERVER_TEXT = ["server/relay.py", "web/index.html", "web/app.js", "web/manifest.webmanifest", "web/icon.svg",
               "Dockerfile", "docker-compose.yml"]
SERVER_BINARY = ["web/apple-touch-icon.png"]
# Every Mac source file is included automatically, so new files can't be forgotten.
MAC_TEXT = ["mac/build.sh"] + sorted(str(p.relative_to(ROOT)) for p in (ROOT / "mac/Sources").glob("*.swift")) \
    + sorted(str(p.relative_to(ROOT)) for p in (ROOT / "mac/ShareExtension").glob("*.swift")) \
    + ["icons/make_icons.swift"]


def text_block(path):
    lang = "dockerfile" if path == "Dockerfile" else LANG.get(Path(path).suffix, "")
    return f"### `{path}`\n\n````{lang}\n{(ROOT / path).read_text().rstrip()}\n````\n"


def binary_block(path):
    b64 = base64.b64encode((ROOT / path).read_bytes()).decode()
    lines = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))
    return (f"### `{path}` (binary; base64)\n\nSave the block below to `{path}.b64`, then run "
            f"`base64 -d < {path}.b64 > {path} && rm {path}.b64`.\n\n````text\n{lines}\n````\n")


def files_section(text, binary=()):
    return "\n".join([text_block(p) for p in text] + [binary_block(p) for p in binary])


def verify(md_path, text, binary=()):
    s = (ROOT / md_path).read_text()
    for name, body in re.findall(r"### `([^`]+)`\n\n````[a-z]*\n(.*?)\n````\n", s, re.S):
        assert name in text and body == (ROOT / name).read_text().rstrip(), f"{md_path}: {name} mismatch"
    for name, body in re.findall(r"### `([^`]+)` \(binary; base64\).*?````text\n(.*?)\n````\n", s, re.S):
        assert base64.b64decode(body.replace("\n", "")) == (ROOT / name).read_bytes(), f"{md_path}: {name} mismatch"
    print(f"{md_path}: {len(text) + len(binary)} files verified, {len(s):,} chars")


SERVER_RULES = """## Ground rules
- Create the files below **byte-for-byte as given**. Don't edit `relay.py` or anything in `web/`. Their crypto and protocol must match the Mac app exactly.
- Don't break anything already running on this server. Back up any reverse-proxy or DNS config before you change it, and show me the diff.
- Never print the admin secret into logs, shell history or git."""

setup = f"""# Task: deploy the Pigeon relay on this server

Pigeon is a small, end-to-end encrypted file and clipboard relay for my devices. The relay is a zero-knowledge mailbox: clients encrypt everything before uploading, so this server only ever stores ciphertext. Please deploy it so it's reachable at **https://{HOST}**.

{SERVER_RULES}
- Show me the admin secret **once**, at the end.
- If something below doesn't fit this server (no Docker, a different proxy, or `{HOST}` already in use), stop and ask me rather than guessing.

## Steps
1. **Look around first.** Find out which OS this is, whether Docker and Docker Compose are installed, which reverse proxy serves {DOMAIN} (Caddy, nginx, Traefik, Cloudflare Tunnel, ...) and how it gets TLS certificates, and whether **public** DNS for `{HOST}` exists. Tell me what you found before changing anything.
2. **Create the files** in `/opt/pigeon` (or wherever this server keeps self-hosted apps), using the layout below.
3. **Create the secret.** Run `umask 077; echo "RELAY_ADMIN_SECRET=$(openssl rand -hex 32)" > /opt/pigeon/.env`. The file must stay mode 600.
4. **Start it.** Run `docker compose up -d --build` in `/opt/pigeon`. The compose file binds the port to `127.0.0.1:8787` only, so it's never exposed directly.
   - Without Docker: create a dedicated unprivileged `pigeon` user and a systemd service that runs `python3 /opt/pigeon/server/relay.py` (Python 3.8+, standard library only). Pass `RELAY_ADMIN_SECRET` through `EnvironmentFile=/opt/pigeon/.env`, set `RELAY_DATA_DIR=/var/lib/pigeon`, and add `Restart=always`. Add sensible hardening such as `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ReadWritePaths=/var/lib/pigeon` and `PrivateTmp=yes`.
5. **Set up HTTPS** for `{HOST}`, proxying to `http://127.0.0.1:8787`, with a real TLS certificate. It must be reachable from the **public internet**, not just my LAN. The proxy must:
   - allow request bodies up to at least **110 MB** (nginx: `client_max_body_size 110m;`)
   - allow upstream reads of at least **60 s**, because clients hold 25-second long-polls (nginx: `proxy_read_timeout 60s;`)
   - pass through the app's own security headers (CSP, HSTS and so on) without overriding them
   - Caddy needs nothing beyond `{HOST} {{ reverse_proxy 127.0.0.1:8787 }}`.
   - If the domain sits behind Cloudflare's proxy (orange cloud), the free plan caps uploads at 100 MB, so set `RELAY_MAX_MB: "95"` in docker-compose.yml.
6. **Verify.** All of these must pass. Show me the output:
   - `curl -s https://{HOST}/api/health` returns `{{"ok": true, "maxMB": ...}}`, both from this server and via public DNS (`dig +short {HOST} @1.1.1.1`)
   - `curl -sI https://{HOST}/` shows a `Content-Security-Policy` header beginning `default-src 'none'`
   - `curl -s -o /dev/null -w '%{{http_code}}' -X POST https://{HOST}/api/inboxes` returns `401`
   - `curl -s -o /dev/null -w '%{{http_code}} %{{content_type}}' https://{HOST}/apple-touch-icon.png` returns `200 image/png`
   - port 8787 is **not** reachable from outside localhost
7. **Report back:**
   - the URL
   - the admin secret, shown once
   - how to view logs, update and restart
   - anything you changed outside `/opt/pigeon`

## Files
{files_section(SERVER_TEXT, SERVER_BINARY)}"""

update = f"""# Update: Pigeon relay to the latest files

Please update the Pigeon relay already running at {HOST}. This update includes every earlier change, so it's safe to apply even if you skipped a previous update.

**What's new:**
- **Delivery receipts.** When the receiving Mac picks an item up, the relay now leaves an empty `<id>.done` marker in the inbox's `items/` folder (swept after the TTL like everything else), and senders can ask `GET /api/inboxes/<id>/receipts?ids=...` (with their send token) whether their items are waiting, delivered or gone. The Mac app uses this to show Delivered / Waiting and to notify when something that had to wait arrives. (Only `relay.py` changed for this; the Mac app verifies it once it's live.)
- **Bug fix.** Error responses (401/404/413) left the keep-alive connection open with an unread request body, which then caused bogus `501` errors on the next request. Connections are now closed after any error.
- **New icon.** There's a new app icon: `web/icon.svg` is replaced, and there's a new `web/apple-touch-icon.png` for the iPhone home screen. `index.html` and `manifest.webmanifest` now point to it, and `relay.py` serves it.

{SERVER_RULES}
- **Keep** the existing `.env` (admin secret) and the data volume or directory. Paired devices depend on them.

## Steps
1. Replace or add these files in the existing install (e.g. `/opt/pigeon`) **byte-for-byte**: `server/relay.py`, `web/index.html`, `web/manifest.webmanifest`, `web/icon.svg`, plus the new `web/apple-touch-icon.png`, which is base64 below. `web/app.js`, `Dockerfile` and `docker-compose.yml` are included for completeness and are unchanged, so leave yours if they match.
2. Rebuild and restart: `docker compose up -d --build`, or restart the systemd service.
3. Verify and show me the output:
   - `curl -s https://{HOST}/api/health` returns `{{"ok": true, ...}}`
   - `curl -s -o /dev/null -w '%{{http_code}} %{{content_type}}' https://{HOST}/apple-touch-icon.png` returns `200 image/png`
   - `curl -s https://{HOST}/icon.svg | head -c 60` starts with `<svg`
   - Keep-alive fix: this prints `401` then `201`, using the real secret without printing it:
     ```bash
     set -a; . /opt/pigeon/.env; set +a
     python3 - <<'PY'
     import http.client, json, secrets, hashlib, os
     h = lambda s: hashlib.sha256(s.encode()).hexdigest()
     body = json.dumps({{"id": secrets.token_urlsafe(16), "sendHash": h(secrets.token_hex()), "recvHash": h(secrets.token_hex())}})
     c = http.client.HTTPConnection("127.0.0.1", 8787)
     c.request("POST", "/api/inboxes", body, {{"Authorization": "Bearer wrong"}}); r = c.getresponse(); r.read(); print(r.status)
     c.request("POST", "/api/inboxes", body, {{"Authorization": "Bearer " + os.environ["RELAY_ADMIN_SECRET"]}}); r = c.getresponse(); r.read(); print(r.status)
     PY
     ```
     (This registers one harmless throwaway inbox.)

## Files
{files_section(SERVER_TEXT, SERVER_BINARY)}"""

other_mac = f"""# Set up Pigeon on this Mac

Pigeon sends text, clipboard contents and files between my Macs, end-to-end encrypted, through my relay at https://{HOST}. It's a small menu bar app. These steps build it from source, so there's nothing to download and no Gatekeeper warnings.

> **Agent:** create the files exactly as given, then build and install. **Don't** enter any admin secret or pairing link yourself. I'll paste those into the app's own dialogs.

## 1. Build and install
1. Make sure the Xcode command line tools are installed: run `xcode-select -p`, and if that fails, run `xcode-select --install` and wait for it to finish.
2. Create a folder such as `~/Pigeon` containing the files below, keeping their paths (`mac/build.sh`, `mac/Sources/*.swift`, `icons/make_icons.swift`).
3. Build and install:
   ```bash
   cd ~/Pigeon && chmod +x mac/build.sh && ./mac/build.sh
   mkdir -p ~/Applications && rm -rf ~/Applications/Pigeon.app && cp -R mac/build/Pigeon.app ~/Applications/
   open ~/Applications/Pigeon.app
   ```
   The build also generates the app and menu bar icons. A pigeon appears in the menu bar. If the menu bar is too full, press **⌃⌥⌘P** to open Pigeon's menu at the mouse pointer.

## 2. Pair it (done by me, not the agent)
For **two-way** (each Mac can send to the other):

1. **Turn on receiving here.** On the welcome screen choose **Receive on This Mac** (or later: click the pigeon → ⚙︎ → Receiving → **Set Up Receiving…**). Enter `https://{HOST}` and paste the relay's admin secret.
2. **Add the work Mac.**
   1. On the **work Mac**, click the pigeon → ⚙︎ → Receiving → **Pair a Device…** → **Copy Link**, and get that link to this Mac (for example, a message to yourself).
   2. Here, click the pigeon → **Add a Mac…** (or Settings → Sending → **Add a Mac…**). The link fills in from the clipboard. Name it "Work Mac".
   3. Check that the fingerprint matches the work Mac's pairing window, then click **It Matches**.
3. **Approve on the work Mac.** The work Mac's pigeon gets a dot, and its popover shows **"Send back to …?"** with this Mac's fingerprint. Click **Allow**. Now both Macs can send to each other.

For **one-way** (this Mac only sends to the work Mac), skip step 1. Without receiving set up here, no request is sent back.

**Sending:** drop files, folders or text on the pigeon or onto its popover, press **⌃⌥⌘V** for the clipboard, or use **Send Files…**. Everything else (where received files go, notifications, history size, clipboard auto-share, launch at login) is in ⚙︎ Settings.

To start Pigeon at login: System Settings → General → Login Items → add Pigeon.

## Files
{files_section(MAC_TEXT)}"""

for name, body, text, binary in [
    ("server-setup-prompt.md", setup, SERVER_TEXT, SERVER_BINARY),
    ("server-update-prompt.md", update, SERVER_TEXT, SERVER_BINARY),
    ("other-mac-setup.md", other_mac, MAC_TEXT, ()),
]:
    (ROOT / name).write_text(body)
    verify(name, text, binary)
