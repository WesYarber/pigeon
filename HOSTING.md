# Hosting the Pigeon relay

Pigeon needs one small server that all your devices can reach over HTTPS: the **relay**. It's a mailbox for encrypted items. Senders upload ciphertext, the receiving Mac downloads it and deletes it. The relay never has a key that can decrypt anything, so it can run anywhere you're comfortable running a small web service.

What you need:

* A machine that's always on: a home server, NAS, Raspberry Pi, or a small VPS (the relay uses a few MB of memory and almost no CPU).
* **Docker** (recommended) or **Python 3.8+**. The relay is a single file with no dependencies beyond Python's standard library.
* A way to give it an **HTTPS address** your devices can reach, including your phone on mobile data. The options below cover your own domain, Cloudflare Tunnel, and Tailscale.

Storage stays small: items are deleted as soon as they're delivered, or after 72 hours if they never are.

## 1. Run the relay

### With Docker (recommended)

```bash
git clone https://github.com/WesYarber/pigeon.git && cd pigeon
echo "RELAY_ADMIN_SECRET=$(openssl rand -hex 32)" > .env && chmod 600 .env
docker compose up -d --build
```

Keep the admin secret somewhere safe (`cat .env`). Each Mac needs it once, to create its inbox. It's never stored on the Mac and isn't needed for sending or receiving.

The container listens on `127.0.0.1:8787` only, so nothing outside the machine can reach it until you put HTTPS in front of it (step 2). Data lives in the `pigeon-data` Docker volume.

Check it's running:

```bash
curl -s http://127.0.0.1:8787/api/health     # {"ok": true, "maxMB": 100}
```

### Without Docker

```bash
git clone https://github.com/WesYarber/pigeon.git && cd pigeon
RELAY_ADMIN_SECRET=$(openssl rand -hex 32) python3 server/relay.py
```

To keep it running, create a systemd service (Linux) with the secret in an environment file readable only by the service user, for example:

```ini
# /etc/systemd/system/pigeon-relay.service
[Unit]
Description=Pigeon relay
After=network-online.target

[Service]
User=pigeon
WorkingDirectory=/opt/pigeon
EnvironmentFile=/opt/pigeon/.env
Environment=RELAY_DATA_DIR=/var/lib/pigeon
ExecStart=/usr/bin/python3 server/relay.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### Settings

All settings are environment variables (in `.env` or `docker-compose.yml`):

| Variable | Default | What it does |
| --- | --- | --- |
| `RELAY_ADMIN_SECRET` | (required) | Needed once per Mac to create an inbox. Use a long random value. |
| `RELAY_MAX_MB` | `100` | Largest item, in MB. Set `95` behind Cloudflare's free plan, which caps uploads at 100 MB. |
| `RELAY_TTL_HOURS` | `72` | Undelivered items are deleted after this long. |
| `RELAY_HOST` / `RELAY_PORT` | `127.0.0.1` / `8787` | Where it listens. Docker sets `0.0.0.0` inside the container and publishes only on localhost. |
| `RELAY_DATA_DIR` | `./data` | Where inboxes and items are stored. |

## 2. Give it an HTTPS address

Pick one. Whatever you choose, the proxy must allow request bodies of at least **110 MB** and upstream reads of at least **60 seconds** (receivers hold 25-second long-polls).

### Your own domain with Caddy (simplest)

Point a DNS record such as `relay.example.com` at your server, open ports 80 and 443, then:

```
relay.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Caddy gets and renews the certificate itself, and its defaults already allow large uploads and long requests.

### Your own domain with nginx

```nginx
server {
    listen 443 ssl;
    server_name relay.example.com;
    # ssl_certificate / ssl_certificate_key from certbot or similar

    client_max_body_size 110m;
    proxy_read_timeout 60s;
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### Cloudflare Tunnel (no open ports, works behind home routers)

With a domain on Cloudflare, install `cloudflared` on the server and create a tunnel (Zero Trust dashboard → Networks → Tunnels) with a public hostname such as `relay.example.com` pointing to the service `http://localhost:8787`.

* Set `RELAY_MAX_MB: "95"` in `docker-compose.yml`: Cloudflare's free plan rejects uploads over 100 MB.
* Cloudflare terminates HTTPS, so it sees connection metadata (sizes, timing, IP addresses), but the content is still end-to-end encrypted.

### Tailscale Funnel (no domain needed)

On the server, with Tailscale installed and Funnel enabled for your tailnet:

```bash
tailscale funnel --bg 8787
```

Your relay is then at `https://<machine>.<tailnet>.ts.net`, reachable from anywhere.

If **every** device that uses Pigeon (Macs, phones) runs Tailscale, you can keep the relay private to your tailnet with `tailscale serve --bg 8787` instead. A work Mac that can't run Tailscale won't be able to reach it then.

### Check it from outside

From a device on another network (a phone on mobile data, for example):

```bash
curl -s https://relay.example.com/api/health                              # {"ok": true, ...}
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://relay.example.com/api/inboxes   # 401
```

Opening `https://relay.example.com/` in a browser shows the web sender page.

## 3. Connect your devices

In the Mac app choose **Receive on This Mac**, enter the HTTPS address and the admin secret, and pair your other devices with the QR code it shows. See [Get started](README.md#get-started).

## Updating

```bash
cd pigeon && git pull && docker compose up -d --build
```

Your `.env` and the data volume are kept, so paired devices keep working. Without Docker, `git pull` and restart the service.

## Backups and moving servers

The data directory holds each inbox's registration (hashes of its tokens) and any items still waiting for delivery. To move to a new server, copy the data directory (or the `pigeon-data` volume) and `.env`, and keep the same HTTPS address; devices won't notice. If you lose the data, each receiving Mac needs to set up receiving again and re-pair its devices.

## Security notes

* The relay only ever stores ciphertext. Sending needs a token that exists only in a pairing link; receiving needs a different token that never leaves the Mac. The relay stores only hashes of both.
* What the relay (and anyone in front of it, such as Cloudflare) can see: when items are sent, how big they are, which inbox they're for, and the IP addresses involved.
* The web sender page is served by the relay, so whoever controls the server could change that page. That's why you host it yourself. The Mac and iPhone apps don't load code from the relay.
* The relay logs only the request method and path shape, never tokens or contents.
