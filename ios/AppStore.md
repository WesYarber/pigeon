# App Store submission: Pigeon for iPhone and iPad

Everything to paste into App Store Connect. Upload builds with `ios/release.sh`.

## App information

| Field | Value |
| --- | --- |
| Name (30 max) | Pigeon: Encrypted File Drop |
| Subtitle (30 max) | Send files to your own Macs |
| Bundle ID | net.wesyarber.pigeon.ios |
| SKU | pigeon-ios |
| Primary category | Utilities |
| Secondary category | Productivity |
| Price | Free (no in-app purchases) |
| Privacy policy URL | https://github.com/WesYarber/pigeon/blob/main/PRIVACY.md |
| Support URL | https://github.com/WesYarber/pigeon |
| Marketing URL | (optional) https://github.com/WesYarber/pigeon |
| Copyright | 2026 Wes Yarber |

## Promotional text (170 max)

Share any file, photo or link from your iPhone straight to your Mac, end-to-end encrypted, through a relay you host. No accounts, no cloud, no tracking.

## Description

Pigeon sends files, photos, links and text from your iPhone or iPad to your own Macs, end-to-end encrypted.

Pick Pigeon in any app's Share sheet and it's on its way: photos keep their original format and name, links arrive ready to open, and text lands on your Mac's clipboard. With one Mac it sends right away; with several, pick which one.

PRIVATE BY DESIGN
• Everything is encrypted on your iPhone to your Mac's key (P-256, AES-256-GCM, a fresh key for every item). Only your Mac can read it.
• It travels through a small relay that you host yourself, on a home server, NAS or VPS. There is no Pigeon cloud, no account, and no tracking.
• Pair by scanning a QR code on your Mac and checking its fingerprint.

MADE FOR SENDING
• Share sheet support for files, photos, videos, links and text
• Photos & Videos, Files and Paste buttons in the app
• See when each item is delivered, even if your Mac was asleep
• On an unfolded iPhone Duo or iPad: a two-pane layout and drag and drop from other apps

REQUIREMENTS
Pigeon needs its free companion Mac app and a relay you host. Their source and setup guides are published at github.com/WesYarber/pigeon.

## Keywords (100 max)

send,transfer,share,file,files,mac,encrypted,private,relay,self-hosted,clipboard,photos,e2e,drop

## What's new (first version)

First release.

## App Privacy ("nutrition label")

**Data Not Collected.** The developer collects nothing: no analytics, accounts, tracking or developer-run servers. Items go, encrypted, to the user's own relay and Macs.

## Export compliance (asked for each build)

* Does your app use encryption? **Yes**
* Does it qualify for any exemptions in Category 5, Part 2? **No** (it encrypts user data end to end)
* Does it implement proprietary or non-standard encryption algorithms? **No.** It uses standard algorithms (ECDH P-256, HKDF-SHA256, AES-256-GCM) through Apple's CryptoKit.
* Result: no documents to upload. US export rules (EAR 740.17(b)(1)) expect an annual self-classification report to BIS for mass-market encryption items. Check the current requirements, and whether distributing in France needs a declaration.

## Age rating

Answer "None" to every content question; no unrestricted web access, no user-generated content shared with others. Expected rating: 4+.

## Review notes (paste into App Review Information; keep the link private)

Pigeon sends files from iPhone to the user's own Mac through a relay server the user hosts. To make testing possible we set up a demo relay inbox:

1. Open Pigeon and tap Add a Mac.
2. Paste this pairing link (or tap Paste after copying it): <PASTE THE REVIEW PROFILE'S PAIRING LINK HERE: Mac → review pigeon → … → Pair a Device → Copy Link>
3. Tap Add Mac. The app now shows Send buttons.
4. Send a photo, file or text from the app, or from any app's Share sheet (choose Pigeon). It's encrypted and uploaded to the demo inbox; Recent shows the item, and "Delivered" once our test Mac picks it up.

The camera is used only to scan a pairing QR code from the Mac app; pasting the link works instead. The companion Mac app and relay are documented at https://github.com/WesYarber/pigeon. The "Leave a Tip" link in Settings appears only on the US storefront.

Contact: pigeon@wesyarber.net

## Screenshots

Ready in `ios/Screenshots/` at Apple's required sizes:

* iPhone 6.9" (1320 × 2868): `iPhone 6.9 - 1 Home.png`, `iPhone 6.9 - 2 Settings.png`
* iPad 13" (2064 × 2752): `iPad 13 - 1 Home.png`

To retake them, run a debug build in a simulator with the launch argument `-ScreenshotDemo` (adds two example Macs on relay.example.com and sample Recent items; nothing is sent), plus `-ScreenshotSettings` to open Settings. That code is only in debug builds.
