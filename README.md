# Pigeon

Send text, screenshots, links and files between your own devices, end-to-end encrypted, through a small relay you host yourself. Macs send and receive from the menu bar; iPhones send from the Share sheet; any browser can send from a web page.

```
 iPhone / Mac / any browser              your relay                      your Mac
 ┌────────────────────────────┐   ciphertext   ┌──────────────┐  ciphertext   ┌───────────────────┐
 │ encrypts to the receiving  │ ─────────────▶ │ relay.py     │ ────────────▶ │ menu bar app      │
 │ Mac's public key           │                │ (can't read) │  long-poll    │ decrypts, copies, │
 └────────────────────────────┘                └──────────────┘               │ keeps history     │
                                                                              └───────────────────┘
```

There's no Pigeon cloud. You run the relay (a single Python file, or a Docker container) on a server, NAS, Raspberry Pi or small VPS you control, and it only ever stores encrypted data it can't read.

## What's here

* **Macs (`mac/`)**: a menu bar app. Click the pigeon for a compact popover: a drop zone (click it to choose files), Send Clipboard, and your recent history (three rows, scroll for more; image thumbnails; click to copy or open). ⚙︎ opens **Settings**: launch at login, Dock icon, notifications, the drop shelf, **how long history is kept** (text 30 minutes and files 2 days by default), **remappable shortcuts**, **Update Pigeon** (pulls the latest from this repository, rebuilds and restarts), **where received files are saved**, what happens when a file arrives, your Macs (rename, default, remove), two-way pairing, clipboard auto-share, and key reset. Each Mac can **receive**, **send**, or both:
  * **Send:** drag files toward the top of the screen and a **drop shelf** slides out under the pigeon with a tile per Mac (dropping on the menu bar itself would open the Spaces bar). You can also drop onto the open popover; it stays open while you drag from Finder. Or drop files or folders on the menu bar icon, press **⌃⌥⌘V** to send your clipboard (text, image or copied files), or use **Send Files…**. **Share Clipboard Automatically** sends everything you copy. It skips copies from password managers and never echoes back something it just received.
  * **Receive:** incoming text goes straight to your clipboard, and the menu keeps your last 50 items. Click one to copy it again. Files are saved to your Downloads folder (change it in Settings → Receiving).
  * **Menu bar full?** macOS hides icons that don't fit, and new ones are hidden first. Press **⌃⌥⌘P** anywhere to open Pigeon's menu at your pointer, or open Pigeon again from Spotlight. Turn on **Show Dock Icon** to drop files on the Dock icon instead; dropping files on Pigeon in Finder also sends them.
  * **From Terminal:** `pigeon report.pdf` sends to your default Mac; `pigeon -t work a.png b.png` picks a Mac by (part of) its name; `echo hi | pigeon` sends text; `pigeon --list` shows your Macs. Folders are zipped. `install.sh` puts the `pigeon` command in the first writable folder on your `PATH` (usually `~/.local/bin`).
  * **Share menu:** choose **Share → Pigeon** on any file in Finder (or other apps). With one Mac it sends right away; with several, a small menu asks which. If Pigeon isn't listed, turn it on under **Edit Extensions…** in the Share menu.
* **iPhone and iPad (`ios/`)**: a send-only app. Add a Mac by scanning the QR code in its **Pair a Device** window (or pasting the link) and checking the fingerprint. Then pick **Pigeon** in any app's Share sheet to send files, photos (original format and name), links or text. With one Mac it sends right away; with several it asks which. The app itself has Photos & Videos, Files and Paste buttons and a Recent list with Delivered / Waiting status. Files over 30 MB shared from the Share sheet wait in an outbox and send when you next open the app (the Share sheet has too little memory for them). Build it with Xcode: `cd ios && xcodegen`, put your team in `ios/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = …`), open `Pigeon.xcodeproj` and run it on your phone. The encryption is the Mac app's own `Crypto.swift`, compiled into the iOS targets.
* **Senders (`web/`)**: a web page served by the relay. Open it on your phone and add it to the home screen. Type or paste text, tap **Paste & send**, or drop and pick files. Pasting an image anywhere on the page sends it.
* **Relay (`server/relay.py`)**: Python standard library only. It's a mailbox for encrypted blobs, which are deleted on delivery or after 72 hours.


## Get started

1. **Host the relay.** Follow [HOSTING.md](HOSTING.md): Docker or plain Python, behind HTTPS (your own domain with Caddy or nginx, a Cloudflare Tunnel, or Tailscale Funnel). You end up with an address like `https://relay.example.com` and an admin secret.
2. **Install the Mac app** on every Mac that should receive (and any that should send). It needs only Apple's command line tools; the script offers to install them:

   ```bash
   git clone https://github.com/WesYarber/pigeon.git && cd pigeon && ./install.sh
   ```

   On first launch choose **Receive on This Mac**, enter your relay's address and admin secret (used once to create this Mac's inbox, never stored), and Pigeon shows a pairing QR code.
3. **Pair your devices.**
   * **Another Mac:** on the receiving Mac, open **… → Pair a Device → Copy Link**; on the other Mac choose **Add a Mac…** and paste it. Check that the fingerprints match. If both Macs receive, accept the **Send back to …?** request for two-way sending.
   * **iPhone or iPad:** build the app in `ios/` (below), then **Add a Mac** and scan the QR code.
   * **Any other device:** scan the QR code with its camera or open the link; the web sender opens. On an iPhone, Share → **Add to Home Screen** makes it feel like an app.

Updates: Pigeon checks this repository every few hours and shows an orange dot on the menu bar icon when there's a new version (Settings → General → Updates, where you can also let it install updates automatically). Or run `git pull && ./install.sh`.

Builds are signed with your Apple Development certificate if you have one (Xcode → Settings → Accounts), so updates keep their Keychain access. Without one, macOS asks you to allow Keychain access after each update; choose **Always Allow**.

### The iPhone app

Needs Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
cd ios && echo "DEVELOPMENT_TEAM = YOURTEAMID" > Config/Local.xcconfig && xcodegen
open Pigeon.xcodeproj   # pick your iPhone and press Run
```

The Share extension shares paired Macs with the app through an app group and a keychain group, so it needs a paid Apple Developer team.

## Security model

| Threat | Protection |
| --- | --- |
| Server compromised | Items are encrypted on the sending device with ECDH P-256, HKDF-SHA256 and AES-256-GCM, using a fresh key for every item. The server never has a decryption key. |
| Someone steals the Mac's key | The private key is created inside the Mac's **Secure Enclave** and can't be exported, even by the app. |
| Tampered or forged items | AES-GCM authentication. Anything modified fails to decrypt and is dropped. |
| Strangers sending you junk | Sending needs a 256-bit token that only exists in the pairing link. Receiving needs a different token that never leaves the Mac. Only the server's hashes of the tokens are stored. |
| Pairing link leaks | The secrets are in the URL `#fragment`, which browsers never send to servers, and the page removes it from the address bar. **Reset Keys & Unpair All Devices** rotates everything. |
| Local snooping on the Mac | History is AES-GCM encrypted at rest with a Keychain key. Received files get the macOS quarantine flag, so Gatekeeper still checks anything executable. |

One caveat: the sender page's JavaScript is served by your relay. If an attacker took over that server, they could serve a modified page that leaks what you type on it *from then on*. That's the usual tradeoff for web-based E2E encryption, and it's why you run the relay yourself. The page uses a strict Content Security Policy, so there are no third-party scripts.

Before trusting a device, check that the fingerprint under **This device** on the page matches the one in the Mac's pairing window.

## Icons and hand-off files

All icons come from one drawing in `icons/make_icons.swift`: the Mac and iPhone app icons, the menu bar pigeon (with a dot when something arrives) and the web icons. `mac/build.sh` regenerates the Mac icons on every build. After changing the drawing, refresh the other copies:

```bash
swift icons/make_icons.swift icons/out && cp icons/out/web/icon.svg icons/out/web/apple-touch-icon.png web/
```

`python3 tools/make_prompts.py` writes self-contained hand-off files (`server-setup-prompt.md`, `server-update-prompt.md`, `other-mac-setup.md`) for setting up a server or another Mac with an AI agent, and checks every embedded file byte for byte. Put your relay's hostname in `tools/relay-host.txt` first (it's gitignored).

## Privacy

Pigeon collects nothing: no accounts, analytics or tracking, and no developer-run servers. See [PRIVACY.md](PRIVACY.md).

## License

Copyright © 2026 Wes Yarber. All rights reserved. The source is published so it can be read and audited; it isn't licensed for reuse. See [LICENSE](LICENSE).
