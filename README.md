<div align="center">

<img src="icon.png" width="120" alt="Unleashed icon">

# Unleashed

**A native iOS companion for Flipper Zero** — files, screen mirror, Sub-GHz/NFC, a Sber smart-relay failsafe, Marauder log analysis, ESP32 firmware flashing, and live Claude Code status on your Flipper.

![version](https://img.shields.io/badge/version-1.1.21-F36E12)
![platform](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.9-orange?logo=swift)
![transport](https://img.shields.io/badge/transport-BLE-blue?logo=bluetooth)
![install](https://img.shields.io/badge/install-Feather%2FAltStore-7B68EE)

</div>

---

## Contents

- [Install](#install-feather--altstore)
- [Screenshots](#screenshots)
- [Features](#features)
- [App Bridge (FAB1 / FAB2)](#app-bridge-fab1--fab2)
- [Firmware packages (atomic updater)](#firmware-packages-atomic-updater)
- [How the relay state works](#how-the-relay-state-works)
- [Privacy](#privacy)
- [Requirements](#requirements)

## Install (Feather / AltStore)

Add the source, then install — Feather signs it with your own certificate and auto-updates on each release:

```
https://raw.githubusercontent.com/squazaryu/unleashed-companion/main/apps.json
```

> Unsigned IPA, sideloaded. Built for the **[tumoflip](https://github.com/squazaryu/tumoflip)** firmware (Unleashed-based — its App Bridge BLE service is what most of the integrations talk to). Works as a plain BLE file/screen client on stock firmware too.

## Screenshots

<p align="center">
  <img src="screenshots/onboarding.png" width="200" alt="Onboarding">
  <img src="screenshots/home.png" width="200" alt="Home dashboard">
  <img src="screenshots/relay.png" width="200" alt="Relay control">
  <img src="screenshots/settings.png" width="200" alt="Settings — themes & app icons">
</p>

<sub>Onboarding · Home dashboard · Relay control · Settings (themes + 5 app icons). Home/Relay are shown without a Flipper paired — the live-data screens (device info, files, screen mirror, WiFi/Marauder, AI Radar, Claude Buddy) look best on a connected device.</sub>

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
- **all-the-plugins** auto-updater and ~daily background notifications for new plugin packs and ESP32 firmware (local only, no account).
- Card-based UI, 5 app icons, light/dark themes, Live Activity for install progress.

## App Bridge (FAB1 / FAB2)

Most integrations talk to a small BLE service in the [tumoflip](https://github.com/squazaryu/tumoflip) firmware. The app negotiates the wire version automatically and shows it in Settings (`v2 (FAB2)` / `v1 (FAB1)`):

- **FAB2** — correlated request/response. Each request carries a monotonic, nonzero id; replies are matched back to it; ordered chunks are reassembled (≤ 512 B); frames are strictly validated (lengths, flags, reserved byte, UTF-8, exact size); firmware errors surface as typed errors; pending requests are cleaned up on timeout or disconnect. v2 is enabled only on a valid `runtime/capabilities` response, and unknown capability keys are preserved.
- **FAB1** — legacy single-frame fallback used for unsolicited events (the Relay and AI Radar event path), so stock / older firmware keeps working.

## Firmware packages (atomic updater)

**Updates → Firmware packages** installs the Base / ARF / Module One / Protocol Pack files from the latest [tumoflip](https://github.com/squazaryu/tumoflip) release onto the Flipper SD as one **crash-consistent transaction**:

- the release manifest (schema v2) is validated and every target path is sanitised;
- each file is staged, SHA-256-checked on download and MD5-verified on the device before any live path is touched;
- activation is write-ahead journalled into dual, checksummed state slots — the Flipper's `storage rename` is copy + remove (not atomic), so an interrupted install is recovered or fully rolled back;
- replaced files and legacy cleanup are reversible, and the connected firmware's target / API / version must match the manifest before any FAP/FAL is written.

> Needs a firmware release that publishes `tumoflip-packages.zip`; until then the screen shows “no install archive yet”. Firmware (DFU) flashing is a separate, explicit step and is not done here.

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
