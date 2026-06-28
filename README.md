<div align="center">

<img src="icon.png" width="120" alt="Unleashed icon">

# Unleashed

**A native iOS companion for Flipper Zero** — BLE/USB SD file access, screen mirror, Sub-GHz/NFC, a Sber smart-relay failsafe, Marauder log analysis, ESP32 firmware flashing, and live Claude Code status on your Flipper.

![version](https://img.shields.io/badge/version-1.2.1-F36E12)
![platform](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.9-orange?logo=swift)
![transport](https://img.shields.io/badge/transport-BLE%20%2B%20USB%20SD-blue?logo=bluetooth)
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

<sub>Onboarding · Home dashboard · Relay control · Settings (themes + app-icon styles). Home/Relay are shown without a Flipper paired — the live-data screens (device info, files, screen mirror, WiFi/Marauder, AI Radar, Claude Buddy) look best on a connected device.</sub>

## Features

### 📱 Device & files
- Connect over Bluetooth LE for live control, App Bridge, screen mirror and RPC actions.
- Browse the SD card over **BLE or USB SD Mode**, **create folders**, upload files and whole folders, multi-select and move items in bulk; one-tap macOS-junk cleanup (`._*`, `.DS_Store`).
- USB SD Mode uses iOS file-provider access: select the Flipper SD card folder in Files once, then the app will try to restore that USB channel on later launches.
- **Screen mirror** with live remote control (D-pad / OK / Back).
- Full **Device Info** (hardware, firmware, radio stack, battery) at a glance.

### 📡 Sub-GHz · NFC · RFID
- Transmit saved Sub-GHz signals and emulate NFC / RFID via the companion `.fap`.
- Remotes list for your everyday captures.

### 📶 WiFi / Marauder analysis
- **Auto-aggregates every** Marauder scan, sniff and Evil Portal log on the SD into one **Overview** — networks → clients → vendors (OUI-resolved), with channel-distribution and top-vendor charts.
- Opens tumoflip **WiFi Mapper** GeoJSON exports from `/ext/apps_data/wifi_mapper/exports` on an interactive map, with clean/raw support, RSSI filtering, observed points, and estimated AP locations from repeated RSSI observations.
- Surfaces **Evil Portal** captured credentials.
- Compact filter (Useful / Captures / Scans / Portal / All) with the statistics pinned at the top; the (often hundreds-strong) file list is collapsed below — tap any single capture to inspect it on its own.
- Parses classic `.pcap` (802.11 / radiotap) and Marauder text logs; finds them in the real `pcaps/` · `logs/` · `dumps/` subfolders automatically.

### 🔌 ESP32 Marauder firmware
- Checks ESP32Marauder releases, detects your board from the esp_flasher layout, downloads the matching image and stages a flash folder over BLE or USB SD — with size guard + MD5 verify.
- Archives outdated staged flash folders into `/ext/apps_data/esp_flasher/_archive` so old Marauder builds do not clutter the normal flashing list; archived folders can be restored or deleted from the ESP32 screen.
- Shows a per-board-key firmware version manager, so C5/WROOM modules keep separate versioned folders and an older build can be restored before flashing from the Flipper.

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
- **Live Activity** for installs (plugin packs *and* firmware packages) — live per-file progress on the lock screen and Dynamic Island, with a screen-awake guard so a long BLE install isn't interrupted.
- **Home-screen widgets** — Quick Actions (deep-link to Files / Screen / Relay / WiFi) and Relay controls. *(Live-data widgets — battery, AI Radar, relay state — need an App-Group-capable signer such as SideStore/AltStore; under Feather only the deep-link widgets are shown.)*
- Card-based UI; **4 app-icon styles** — Light, Dark, Liquid Glass, Liquid Glass · Dark — plus an **Auto** icon that follows the system appearance; light/dark themes.

## App Bridge (FAB1 / FAB2)

Most integrations talk to a small BLE service in the [tumoflip](https://github.com/squazaryu/tumoflip) firmware. The app negotiates the wire version automatically and shows it in Settings (`v2 (FAB2)` / `v1 (FAB1)`):

- **FAB2** — correlated request/response. Each request carries a monotonic, nonzero id; replies are matched back to it; ordered chunks are reassembled (≤ 512 B); frames are strictly validated (lengths, flags, reserved byte, UTF-8, exact size); firmware errors surface as typed errors; pending requests are cleaned up on timeout or disconnect. v2 is enabled only on a valid `runtime/capabilities` response, and unknown capability keys are preserved.
- **FAB1** — legacy single-frame fallback used for unsolicited events (the Relay and AI Radar event path), so stock / older firmware keeps working.

## Firmware packages (atomic updater)

**Updates → Firmware packages** installs the Base / ARF / Module One / Protocol Pack files from the latest [tumoflip](https://github.com/squazaryu/tumoflip) release onto the Flipper SD over BLE or USB SD Mode as one **crash-consistent transaction**:

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
