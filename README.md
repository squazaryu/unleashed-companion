<div align="center">

<img src="icon.png" width="120" alt="Unleashed icon">

# Unleashed

**A native iOS companion for Flipper Zero** — files, screen mirror, Sub-GHz/NFC, a Sber smart-relay failsafe, Marauder log analysis, ESP32 firmware flashing, and live Claude Code status on your Flipper.

![version](https://img.shields.io/badge/version-1.1.4-F36E12)
![platform](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.9-orange?logo=swift)
![transport](https://img.shields.io/badge/transport-BLE-blue?logo=bluetooth)
![install](https://img.shields.io/badge/install-Feather%2FAltStore-7B68EE)

</div>

---

## Install (Feather / AltStore)

Add the source, then install — Feather signs it with your own certificate and auto-updates on each release:

```
https://raw.githubusercontent.com/squazaryu/unleashed-companion/main/apps.json
```

> Unsigned IPA, sideloaded. Built for the **[tumoflip](https://github.com/squazaryu/tumoflip)** firmware (Unleashed-based — its App Bridge BLE service is what most of the integrations talk to). Works as a plain BLE file/screen client on stock firmware too.

## Features

### 📱 Device & files
- Connect over Bluetooth LE — no cable, no USB.
- Browse the SD card, upload files and whole folders, long-press to move.
- **Screen mirror** with live remote control (D-pad / OK / Back).
- Full **Device Info** (hardware, firmware, radio stack, battery) at a glance.

### 📡 Sub-GHz · NFC · RFID
- Transmit saved Sub-GHz signals and emulate NFC / RFID via the companion `.fap`.
- Remotes list for your everyday captures.

### 📶 WiFi / Marauder analysis
- Import a Marauder `.pcap` and get a structured view: **networks → clients → vendors** (OUI-resolved), not a raw dump.
- Surfaces **Evil Portal** captured credentials from sniff logs.
- File picker to browse the SD and pick any capture.

### 🔌 ESP32 Marauder firmware
- Checks ESP32Marauder releases, detects your board from the esp_flasher layout, downloads the matching image and stages a flash folder — with size guard + MD5 verify.

### 🛰️ Sber relay failsafe
- Toggle a Sber smart relay straight from the Flipper via App Bridge events.
- **Auto route:** local Home Assistant webhook first, automatic failover to the **Sber cloud** — so the Mac/HA isn't required.
- In-app **Sber login** (OAuth Authorization Code + PKCE) — tokens live in the iOS Keychain, never in the build.
- Siri App Intents: *"toggle the relay."*

### 🤖 Claude Buddy
- Live **Claude Code** status on the Flipper screen — thinking / running tool / turn complete — plus a session token counter, streamed over BLE serial through a small Mac relay daemon.
- Mic button toggles Claude Code's in-app dictation (⌘D), layout-independent.

### 🔔 Quality of life
- App Bridge **v2 (FAB2)** negotiated automatically, with v1 fallback.
- Correlated FAB2 requests with strict frame validation, ordered chunk
  reassembly, typed firmware errors, and timeout/disconnect cleanup.
- Transactional tumoflip SD package updates with manifest validation, staging,
  on-device hash checks, reversible cleanup, recovery, and rollback.
- **all-the-plugins** auto-updater and ~daily background notifications for new plugin packs and ESP32 firmware (local only, no account).
- Card-based UI, 5 app icons, light/dark themes, Live Activity for install progress.

## How the relay state works

The Sber relay doesn't report a reliable *steady* state back to Home Assistant (the sberdevices entity reverts to off seconds after an on command; the template-switch mirror sticks). So the on/off pill **follows your last command** — from the app or the Flipper — and is persisted across launches. The optional *"Test read state"* in Relay Settings is a comparison-only diagnostic.

## Privacy

- **No telemetry, no analytics, no account.**
- Sber / Home Assistant tokens are stored in the **iOS Keychain** and entered by you — nothing personal is baked into the build.
- Update notifications are **local** (`BGAppRefreshTask` + local notifications); they only fetch public GitHub release tags.
- Bundles the public Russian Trusted Root CA so Sber's TLS validates — no private keys involved.

## Requirements

- iPhone on **iOS 17+**, a Flipper Zero, and (for most integrations) the **[tumoflip](https://github.com/squazaryu/tumoflip)** firmware (Unleashed-based) with App Bridge.
- Optional: a Mac running the AI Radar / Claude Buddy relay daemon for the Claude Code features and the HA relay bridge.

## Releases

See [Releases](https://github.com/squazaryu/unleashed-companion/releases) for the changelog and IPAs. `apps.json` is the Feather source manifest.

<div align="center"><sub>Built for personal use with the Flipper Zero community. Not affiliated with Flipper Devices, Sber, or Anthropic.</sub></div>
