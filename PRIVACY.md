# Pigeon privacy policy

_Last updated: November 2026_

Pigeon sends text, links and files between your own devices. It's built so that nobody but you can read what you send, including me, the developer.

## What the developer collects

Nothing. Pigeon has no accounts, analytics, advertising, tracking or crash reporting, and it doesn't send anything to servers run by the developer. The developer doesn't operate a Pigeon service.

## Where your data goes

* **Your relay.** Pigeon sends everything through a relay server that **you** set up and control (see [HOSTING.md](HOSTING.md)). Before anything leaves your device it's encrypted to the receiving Mac's key (ECDH P-256, HKDF-SHA256, AES-256-GCM, a fresh key for every item). The relay only ever stores this ciphertext and deletes it once your Mac picks it up, or after 72 hours.
* **What your relay can see.** Like any server, your relay (and anything in front of it, such as Cloudflare if you use it) sees connection details: your IP address, when items are sent, how big they are, and which inbox they're for. It can't see their contents or file names.
* **On your devices.** Paired Macs (including their send tokens) are kept in your device's Keychain. A short list of what you've sent recently (names or the first words of text, and whether each was delivered) is kept on your device so the app can show it. You can clear it in Settings. Pigeon doesn't sync anything to iCloud. Your paired Macs never leave the device (not even in backups); the recent list is ordinary app data, so it's included in your device's own backups like any app's.

## Permissions

* **Camera:** only to scan the pairing QR code your Mac shows. Images aren't saved or sent.
* **Photos and files:** Pigeon only sees the photos and files you pick or share to it, and only to send them where you choose.
* **Clipboard:** Pigeon reads the clipboard only when you tap Paste.

## Feedback and tips

If you email feedback to pigeon@wesyarber.net, I'll see your email address and whatever you write, and use them only to reply. The optional "Leave a Tip" link (shown in the US) opens Ko-fi in your browser; Ko-fi's own privacy policy applies there.

## Children

Pigeon isn't directed at children and collects no data from anyone.

## Changes

Any changes to this policy will be published here, in the app's public repository.

## Contact

pigeon@wesyarber.net
