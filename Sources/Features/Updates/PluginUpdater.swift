import Foundation
import CryptoKit
import ZIPFoundation
import os

private let ulog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "updates")

enum PluginInstallRouting {
    static let targetPaths: [String: String] = [
        "air_mouse": "/ext/apps/Module One/AirMouse BMI160/air_mouse.fap",
        "airmon": "/ext/apps/Module One/ESP32 Wi-Fi/airmon.fap",
        "esp32_wifi_marauder": "/ext/apps/Module One/ESP32 Wi-Fi/esp32_wifi_marauder.fap",
        "esp_flasher": "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
        "evil_portal": "/ext/apps/Module One/ESP32 Wi-Fi/evil_portal.fap",
        "flipper_share": "/ext/apps/Module One/Sub-GHz/flipper_share.fap",
        "flipper_xremote": "/ext/apps/Module One/IR Blaster/tumoflip_xremote.fap",
        "freq_analyzer_ext": "/ext/apps/Module One/Sub-GHz/freq_analyzer_ext.fap",
        "ghost_esp": "/ext/apps/Module One/ESP32 Wi-Fi/ghost_esp.fap",
        "gps_nmea": "/ext/apps/Module One/GPS/gps_nmea.fap",
        "gps_track": "/ext/apps/Module One/GPS/gps_track.fap",
        "ibutton_converter": "/ext/apps/Module One/iButton/ibutton_converter.fap",
        "ir_intervalometer": "/ext/apps/Module One/IR Blaster/ir_intervalometer.fap",
        "ir_remote": "/ext/apps/Module One/IR Blaster/ir_remote.fap",
        "ir_scope": "/ext/apps/Module One/IR Blaster/ir_scope.fap",
        "nrf24_batch": "/ext/apps/Module One/NRF24/nrf24_batch.fap",
        "nrf24_mouse_jacker": "/ext/apps/Module One/NRF24/nrf24_mouse_jacker.fap",
        "nrf24_mouse_jacker_ms": "/ext/apps/Module One/NRF24/nrf24_mouse_jacker_ms.fap",
        "nrf24_scanner": "/ext/apps/Module One/NRF24/nrf24_scanner.fap",
        "nrf24_sniffer": "/ext/apps/Module One/NRF24/nrf24_sniffer.fap",
        "nrf24_sniffer_ms": "/ext/apps/Module One/NRF24/nrf24_sniffer_ms.fap",
        "nrf24channelscanner": "/ext/apps/Module One/NRF24/nrf24channelscanner.fap",
        "nrf24tool": "/ext/apps/Module One/NRF24/nrf24tool.fap",
        "proto_pirate": "/ext/apps_data/arf_subghz_full/modules/proto_pirate.fap",
        "protoview": "/ext/apps/Module One/Sub-GHz/protoview.fap",
        "radio_scanner": "/ext/apps/Module One/Sub-GHz/radio_scanner.fap",
        "spectrum_analyzer": "/ext/apps/Module One/Sub-GHz/spectrum_analyzer.fap",
        "sub_analyzer": "/ext/apps/Module One/Sub-GHz/sub_analyzer.fap",
        "subghz_bruteforcer": "/ext/apps_data/arf_subghz_full/modules/subghz_bruteforcer.fap",
        "subghz_playlist": "/ext/apps/Module One/Sub-GHz/subghz_playlist.fap",
        "subghz_playlist_creator": "/ext/apps/Module One/Sub-GHz/subghz_playlist_creator.fap",
        "subghz_raw_edit": "/ext/apps/ARF Tools/subghz_raw_edit.fap",
        "subghz_signal_gen": "/ext/apps/Module One/Sub-GHz/subghz_signal_gen.fap",
        "subghz_wardriving": "/ext/apps/Module One/Sub-GHz/subghz_wardriving.fap",
        "timed_remote": "/ext/apps/Module One/IR Blaster/timed_remote.fap",
        "tpms": "/ext/apps/Module One/Sub-GHz/tpms.fap",
        "ublox": "/ext/apps/Module One/GPS/ublox.fap",
        "unitemp": "/ext/apps/Module One/Sensors BME280/unitemp.fap",
        "vario": "/ext/apps/Module One/Sensors BME280/vario.fap",
        "weather_station": "/ext/apps/Module One/Sub-GHz/weather_station.fap",
        "wifi_map": "/ext/apps/Module One/ESP32 Wi-Fi/wifi_map.fap",
        "wifi_scanner": "/ext/apps/Module One/ESP32 Wi-Fi/wifi_scanner.fap",
        "wmbuster": "/ext/apps/Module One/Sub-GHz/wmbuster.fap",
    ]

    static func targetPath(for remotePath: String) -> String {
        let appName = ((remotePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
        return targetPaths[appName] ?? remotePath
    }

    static func remotePath(for archivePath: String) -> String? {
        for marker in ["artifacts-base/", "artifacts-extra/"] {
            if let range = archivePath.range(of: marker) {
                return "/ext/apps/" + archivePath[range.upperBound...]
            }
        }
        if let range = archivePath.range(of: "apps_data/") {
            return "/ext/apps_data/" + archivePath[range.upperBound...]
        }
        return nil
    }
}

enum PluginProtectionPolicy {
    /// Data-only plugin families whose binary names do not match the owning app.
    /// Protect the family as one unit so a catalog update cannot mix an upstream
    /// FAL set with Tumoflip's corresponding FAP or protocol pack.
    private static let dataFamilyOwners: [(prefix: String, owner: String)] = [
        ("/ext/apps_data/arf_subghz_full/", "arf_subghz_full"),
        ("/ext/apps_data/rolljam_standalone/", "rolljam"),
        ("/ext/apps_data/subghz/plugins/", "subghz_protocols"),
        ("/ext/apps_data/totp/", "totp"),
    ]

    static func protectionKeys(name: String, remotePath: String) -> Set<String> {
        var keys = [name.lowercased()]
        if let family = dataFamilyOwners.first(where: { remotePath.hasPrefix($0.prefix) }) {
            keys.append(family.owner)
        } else if remotePath.hasPrefix("/ext/apps_data/") {
            let suffix = remotePath.dropFirst("/ext/apps_data/".count)
            if let root = suffix.split(separator: "/").first {
                keys.append(String(root).lowercased())
            }
        }
        return Set(keys)
    }

    static func isProtected(
        name: String,
        remotePath: String,
        excluded: Set<String>,
        unprotectedBuiltIns: Set<String>
    ) -> Bool {
        protectionKeys(name: name, remotePath: remotePath).contains {
            excluded.contains($0) && !unprotectedBuiltIns.contains($0)
        }
    }
}

struct PluginUpdate: Identifiable {
    let id = UUID()
    let remotePath: String   // /ext/apps/<Category>/<app>.fap
    let name: String
    let category: String
    let pack: String         // "base" | "extra"
    let newMD5: String
    let oldMD5: String?      // device/cache md5 (nil = not installed)
    let size: Int
    var selected = true
    var isNew: Bool { oldMD5 == nil }
    var targetPath: String { PluginInstallRouting.targetPath(for: remotePath) }
    var isRouted: Bool { targetPath != remotePath }
    var targetCategory: String {
        let parent = (targetPath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

enum PluginCatalogMetadata: Equatable {
    case parsed(FapMetadata)
    case invalid
}

enum PluginSelectionPolicy {
    static func classify(
        _ catalog: [String: PluginCatalogMetadata],
        deviceApiMajor: Int?,
        deviceTarget: Int?
    ) -> [String: FapCompatibilityState] {
        catalog.mapValues { metadata in
            switch metadata {
            case .parsed(let value):
                return FapCompatibility.classify(
                    value,
                    deviceApiMajor: deviceApiMajor,
                    deviceTarget: deviceTarget)
            case .invalid:
                return FapCompatibility.classify(
                    nil,
                    deviceApiMajor: deviceApiMajor,
                    deviceTarget: deviceTarget)
            }
        }
    }

    static func isInstallable(
        _ update: PluginUpdate,
        classifications: [String: FapCompatibilityState]
    ) -> Bool {
        classifications[update.remotePath]?.isInstallable == true
    }

    static func deselectBlocked(
        _ updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices
        where !isInstallable(updates[index], classifications: classifications) {
            updates[index].selected = false
        }
    }

    static func selectedInstallable(
        _ updates: [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) -> [PluginUpdate] {
        updates.filter {
            $0.selected && isInstallable($0, classifications: classifications)
        }
    }

    static func setSelected(
        _ selected: Bool,
        id: PluginUpdate.ID,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        guard let index = updates.firstIndex(where: { $0.id == id }) else { return }
        updates[index].selected = selected && isInstallable(
            updates[index], classifications: classifications)
    }

    static func setSelected(
        _ selected: Bool,
        where matches: (PluginUpdate) -> Bool,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices where matches(updates[index]) {
            updates[index].selected = selected && isInstallable(
                updates[index], classifications: classifications)
        }
    }

    static func selectOnly(
        where matches: (PluginUpdate) -> Bool,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices {
            updates[index].selected = matches(updates[index]) && isInstallable(
                updates[index], classifications: classifications)
        }
    }
}

enum UpdaterPhase: Equatable {
    case idle, fetching, downloading, needsBaseline, scanning(Int, Int), installing(Int, Int), verifying(Int, Int), done(String), failed(String)
}

/// Outcome of a signature check — either the per-file verification done during an
/// install, or an on-demand "Verify on device" re-hash of the whole pack.
struct VerifyResult: Equatable {
    enum Kind { case postInstall, onDevice }
    let kind: Kind
    let tag: String
    let verified: Int
    let failed: [String]   // "name: reason" for files that didn't match on device
    var ok: Bool { failed.isEmpty }
}

/// Outcome of the post-install legacy-duplicate sweep: for routed apps, the old
/// pre-routing copy at the source path is removed ONLY when it byte-matches what we
/// just installed (md5 == newMD5); anything that differs is kept for manual review.
struct CleanupResult: Equatable {
    let removed: [String]   // legacy duplicate paths deleted (exact pack match)
    let kept: [String]      // legacy paths kept because their md5 differs
    var isEmpty: Bool { removed.isEmpty && kept.isEmpty }
}

struct InstallRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let tag: String
    let name: String
    let pack: String
    let wasNew: Bool
}

/// One dated build in the all-the-plugins release history — xMasterX sometimes ships
/// a same-day follow-up (tag suffixed "p2", "p3", …) when the first cut needed a fix,
/// so "latest" isn't always the only build worth offering; `hasPacks` excludes any
/// release whose base/extra zip assets are missing (a botched or in-progress upload).
struct PluginReleaseInfo: Identifiable, Equatable {
    let tag: String
    let publishedAt: Date
    let hasPacks: Bool
    var id: String { tag }
}

/// Protected apps are intentionally not overwritten by all-the-plugins, but we
/// still surface their upstream/device state so important fixes are not hidden.
struct ProtectedPluginReview: Identifiable, Equatable {
    let remotePath: String
    let targetPath: String
    let name: String
    let category: String
    let pack: String
    let newMD5: String
    let deviceMD5: String?
    let deviceKnown: Bool
    let size: Int

    var id: String { remotePath }
    var needsReview: Bool { deviceKnown && deviceMD5 != newMD5 }
    var isRouted: Bool { targetPath != remotePath }
    var targetCategory: String {
        let parent = (targetPath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

/// Live progress for the file currently being written, so the UI can show a
/// real moving bar instead of an indeterminate spinner.
struct InstallDetail: Equatable {
    var name: String
    var sent: Int
    var total: Int
    var attempt: Int   // 1-based; >1 means we're retrying after a link blip
    var channel: TransferChannel = .ble
}

/// Pulls the latest all-the-plugins build straight from xMasterX's public GitHub
/// releases, fingerprints every .fap and installs ONLY the ones that changed
/// since the last sync — base + extra packs.
@MainActor
final class PluginUpdater: ObservableObject {
    @Published var phase: UpdaterPhase = .idle
    @Published var tag = ""
    @Published private(set) var updates: [PluginUpdate] = []
    /// Set after a device scan: how many apps DIFFER from the pack (these may be
    /// your own modifications, so they default to unselected pending review).
    @Published var changedFromScan = 0
    /// App name-stems (lowercased, no .fap) the updater must NEVER touch — your
    /// locally-modified builds. They're skipped entirely: not shown, not written.
    @Published var excluded: Set<String> = PluginUpdater.loadExcluded()
    /// Built-in protections the user has explicitly lifted. A name here is no longer
    /// protected even though it's in `builtInExcluded`, so all-the-plugins may overwrite it.
    @Published var unprotectedBuiltIns: Set<String> = PluginUpdater.loadUnprotected()
    /// Protected apps present in the upstream pack, compared against the device.
    @Published var protectedReviews: [ProtectedPluginReview] = []
    /// Protected items that genuinely need a look: device state unknown yet, or the
    /// upstream pack differs from what's installed. Shared by the Updates "More" subtitle
    /// and the Protected Apps screen's "Needs review" section.
    var pendingProtectedReview: [ProtectedPluginReview] {
        protectedReviews.filter {
            !$0.deviceKnown || $0.needsReview || !classification($0.remotePath).isCompatible
        }
    }
    @Published var history: [InstallRecord] = PluginUpdater.loadHistory()
    /// Per-file write progress for the install currently in flight (nil when idle).
    @Published var installDetail: InstallDetail?
    /// Result of the last install verification or on-device verify (nil until one runs).
    @Published var verifyResult: VerifyResult?
    /// Result of the post-install legacy-duplicate sweep (nil until an install runs).
    @Published var lastCleanup: CleanupResult?
    /// nil = always use GitHub's "latest" release; set = pin to this exact tag (e.g. to
    /// pick up a same-day "p2" follow-up that "latest" hasn't reflected yet, or to roll
    /// back to a known-good build). Persisted so the pin survives relaunches.
    @Published var manualReleaseTag: String? = PluginUpdater.loadManualReleaseTag()
    @Published var availableReleases: [PluginReleaseInfo] = []
    @Published var loadingReleases = false

    /// Whether an on-device "Verify on device" pass can run — needs the pack manifest
    /// loaded by a prior check (so we know expected md5s and have data to reinstall).
    var canVerifyOnDevice: Bool { !allManifest.isEmpty }

    private let repo = "xMasterX/all-the-plugins"
    private static let excludedKey = "pluginExcluded"
    static let builtInExcluded: Set<String> = [
        "ai_dashboard",
        "app_bridge_terminal",
        "arf_car_emulate",
        "arf_counter_bf",
        "arf_frequency_analyzer",
        "arf_keeloq",
        "arf_psa_decrypt",
        "arf_status",
        "arf_subghz",
        "arf_subghz_full",
        "ble_gatt_lab",
        "claude_buddy",
        "esp32_wifi_marauder",
        "field_logger",
        "flipper_companion",
        "flipper_relay",
        "flipper_xremote",
        "garage_door_remote",
        "keeloq_keystore_decryptor",
        "module_one_cockpit",
        "module_one_sensor_logger",
        "nfc_ccid_bridge",
        "protocol_compiler",
        "proto_pirate",
        "quac",
        "rolljam",
        "rolljam_standalone",
        "runtime_trace_viewer",
        "signal_workbench",
        "subghz_bruteforcer",
        "subghz_protocols",
        "subghz_raw_edit",
        "totp",
        "tumo_acceptance_suite",
        "tumo_ir_lab",
        "tumo_macro_deck",
        "tumocard_os",
        "tumofabric_node",
        "tumoflip_xremote",
        "tumoflip_packages",
        "tumokey_phase_a",
        "tumomodule_runtime",
        "tumonet_bench",
        "tumonet_gateway",
        "tumoscope",
        "tumoscript",
        "tumovgm_bridge",
        "tumovm_peripherals",
        "tumovm_poc",
        "usb_sd_mode",
        "wifi_mapper",
    ]
    private static let retiredBuiltInExcluded: Set<String> = ["ble_killer"]

    var builtInProtectedNames: [String] {
        Self.builtInExcluded.sorted()
    }

    var customProtectedNames: [String] {
        excluded.subtracting(Self.builtInExcluded).sorted()
    }

    /// Effective protection: excluded AND not lifted via `unprotectedBuiltIns`.
    func isProtected(_ name: String) -> Bool {
        let n = name.lowercased()
        return excluded.contains(n) && !unprotectedBuiltIns.contains(n)
    }

    func isProtected(_ update: PluginUpdate) -> Bool {
        PluginProtectionPolicy.isProtected(
            name: update.name,
            remotePath: update.remotePath,
            excluded: excluded,
            unprotectedBuiltIns: unprotectedBuiltIns)
    }

    func isBuiltInUnprotected(_ name: String) -> Bool {
        unprotectedBuiltIns.contains(name.lowercased())
    }

    // Per-fap md5 of the pack state we last reconciled with the device.
    private struct Cache: Codable { var tag: String; var map: [String: String] }
    private let cacheKey = "pluginPackCache.v2"

    // Working files for the current check (kept for install pass).
    private var packURLs: [(pack: String, url: URL)] = []
    private var allManifest: [String: PluginUpdate] = [:]   // remotePath -> entry (no data)
    private var protectedManifest: [PluginUpdate] = []

    var selectedCount: Int { installableSelectedCount }

    // MARK: - FAP/FAL compatibility (issue #19)

    /// Parsed `.fapmeta` for every catalog binary — computed ONCE during Check in the
    /// same archive pass that already MD5s each file. Covers base + extra and BOTH
    /// installable AND protected apps. Re-classification against a (re)connected device
    /// reuses this without re-downloading or re-parsing the archives.
    @Published private(set) var catalogMeta: [String: PluginCatalogMetadata] = [:]

    /// Fresh connected-firmware identity from the last classification (nil = unknown).
    @Published private(set) var deviceApiMajor: Int?
    @Published private(set) var deviceTarget: Int?

    /// Per-catalog-binary compatibility state (remotePath → state), recomputed from
    /// `catalogMeta` + the fresh device identity. The single source the UI, the selection
    /// policy, and the install gate all read.
    @Published private(set) var classifications: [String: FapCompatibilityState] = [:]
    @Published private(set) var validating = false

    func classification(_ remotePath: String) -> FapCompatibilityState {
        classifications[remotePath] ?? .unvalidated(FapCompatibility.unknownDeviceReason)
    }
    func isInstallable(_ u: PluginUpdate) -> Bool { classification(u.remotePath).isInstallable }
    func reason(_ u: PluginUpdate) -> String? { classification(u.remotePath).reason }

    /// `updates` split by installability, for the UI partition (installable categories vs
    /// the collapsed "Incompatible" section).
    var installableUpdates: [PluginUpdate] { updates.filter { isInstallable($0) } }
    var blockedUpdates: [PluginUpdate] { updates.filter { !isInstallable($0) } }

    /// Only installable AND selected — drives the install button count / plan. `selected`
    /// is kept ⊆ installable by the selection policy, but this stays defensive.
    var installableSelectedCount: Int {
        PluginSelectionPolicy.selectedInstallable(
            updates, classifications: classifications).count
    }

    // MARK: Selection policy — the UI never sets `.selected` directly; it routes through
    // these, which refuse to select unvalidated/incompatible entries.

    func setSelected(_ on: Bool, id: PluginUpdate.ID) {
        PluginSelectionPolicy.setSelected(
            on, id: id, updates: &updates, classifications: classifications)
    }
    func setSelected(_ on: Bool, where match: (PluginUpdate) -> Bool) {
        PluginSelectionPolicy.setSelected(
            on, where: match, updates: &updates, classifications: classifications)
    }
    func selectOnly(where match: (PluginUpdate) -> Bool) {
        PluginSelectionPolicy.selectOnly(
            where: match, updates: &updates, classifications: classifications)
    }

    /// Fresh device firmware API major + hardware target (both nil when unreachable). A
    /// stale cached identity is NEVER used as the install-time identity — this always
    /// reads device_info over a BLE-ready link.
    private func deviceApiTarget() async -> (api: Int?, target: Int?) {
        guard FlipperBLE.shared.state == .ready, let info = try? await FlipperSystem().deviceInfo() else {
            return (nil, nil)
        }
        let dict = Dictionary(info, uniquingKeysWith: { a, _ in a })
        return (dict["firmware_api_major"].flatMap(Int.init), dict["hardware_target"].flatMap(Int.init))
    }

    private func fapCandidates(_ entries: [PluginUpdate]) -> [PackageCompatibilityGate.Candidate] {
        entries.map { update in
            PackageCompatibilityGate.Candidate(
                id: update.remotePath,
                target: update.targetPath,
                data: { self.extractData(remotePath: update.remotePath) })
        }
    }

    /// Re-read fresh device identity and re-classify the WHOLE catalog from the cached
    /// parsed metadata (no re-download / re-parse), then drop any now-blocked selection.
    /// Runs after every path that (re)builds `updates` — Check (Auto & pinned), first-run
    /// Scan, Verify on device — and on reconnect.
    func validateCompatibility() async {
        guard !catalogMeta.isEmpty else { classifications = [:]; return }
        // Don't re-classify while an install is in flight. A long install drops &
        // re-establishes BLE per app; each `ble.state` blip re-fires this via the
        // detail/Updates `.task(id: ble.state)` hooks, and during the reconnect
        // `deviceApiTarget()` reports (nil,nil) → every app flips to .unvalidated →
        // the category list collapses to just "incompatible" and back, thrashing the
        // card heights mid-animation (visible z-fight) and contending with the
        // transfer over RPC (issue #21). install() runs its own inline gate, so
        // skipping here loses nothing; the post-install .ready settle revalidates.
        if case .installing = phase { return }
        validating = true
        defer { validating = false }
        let (api, target) = await deviceApiTarget()
        deviceApiMajor = api
        deviceTarget = target
        classifications = PluginSelectionPolicy.classify(catalogMeta, deviceApiMajor: api, deviceTarget: target)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: classifications)
    }

    // MARK: - Check

    func check() async {
        do {
            phase = .fetching
            updates = []
            changedFromScan = 0
            protectedReviews = []
            verifyResult = nil
            catalogMeta = [:]
            classifications = [:]
            let (tag, assets) = try await latestRelease()
            self.tag = tag

            phase = .downloading
            var manifest: [String: PluginUpdate] = [:]
            var protected: [PluginUpdate] = []
            var metadata: [String: PluginCatalogMetadata] = [:]
            packURLs = []
            for (pack, name) in [("base", "all-the-apps-base.zip"), ("extra", "all-the-apps-extra.zip")] {
                guard let asset = assets[name] else { continue }
                let url = try await download(asset, to: "atp-\(pack).zip")
                packURLs.append((pack, url))
                let extracted = try extractManifest(zipURL: url, pack: pack)
                metadata.merge(extracted.metadata) { _, new in new }
                for f in extracted.updates {
                    if isProtected(f) {
                        protected.append(f)
                        continue
                    }
                    manifest[f.remotePath] = f
                }
            }
            allManifest = manifest
            protectedManifest = sortUpdates(protected)
            catalogMeta = metadata
            await refreshProtectedReviews()

            if let cacheMap = loadCache()?.map, !cacheMap.isEmpty {
                // Fast path: diff the new pack against what we last reconciled.
                var result: [PluginUpdate] = []
                for (path, f) in manifest {
                    if cacheMap[path] != f.newMD5 {
                        var update = PluginUpdate(
                            remotePath: path,
                            name: f.name,
                            category: f.category,
                            pack: f.pack,
                            newMD5: f.newMD5,
                            oldMD5: cacheMap[path],
                            size: f.size)
                        // New all-the-plugins entries should be reviewed manually; otherwise
                        // a broad pack update can quietly fill the SD with duplicates.
                        update.selected = cacheMap[path] != nil
                        result.append(update)
                    }
                }
                updates = sortUpdates(result)
                phase = updates.isEmpty ? .done("Everything up to date · \(tag)") : .idle
            } else {
                // No baseline yet — let the user choose how to seed it.
                phase = .needsBaseline
            }
            await validateCompatibility()
        } catch {
            ulog.error("check failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func sortUpdates(_ r: [PluginUpdate]) -> [PluginUpdate] {
        r.sorted { ($0.pack, $0.category, $0.name) < ($1.pack, $1.category, $1.name) }
    }

    private func sortProtected(_ r: [ProtectedPluginReview]) -> [ProtectedPluginReview] {
        r.sorted { ($0.pack, $0.category, $0.name) < ($1.pack, $1.category, $1.name) }
    }

    private func refreshProtectedReviews() async {
        guard !protectedManifest.isEmpty else {
            protectedReviews = []
            return
        }

        let items = protectedManifest
        let channel = activeChannel
        guard await fileChannelReady(channel, timeout: 2) else {
            protectedReviews = sortProtected(items.map {
                ProtectedPluginReview(
                    remotePath: $0.remotePath,
                    targetPath: $0.targetPath,
                    name: $0.name,
                    category: $0.category,
                    pack: $0.pack,
                    newMD5: $0.newMD5,
                    deviceMD5: nil,
                    deviceKnown: false,
                    size: $0.size)
            })
            return
        }

        let storage = activeStorage
        var result: [ProtectedPluginReview] = []
        for f in items {
            result.append(ProtectedPluginReview(
                remotePath: f.remotePath,
                targetPath: f.targetPath,
                name: f.name,
                category: f.category,
                pack: f.pack,
                newMD5: f.newMD5,
                deviceMD5: await storage.md5(f.targetPath),
                deviceKnown: true,
                size: f.size))
        }
        protectedReviews = sortProtected(result)
    }

    /// First-run option A: scan the Flipper so we flag exactly what's missing/old.
    func scanBaseline() async {
        let channel = activeChannel
        let storage = activeStorage
        guard await fileChannelReady(channel) else {
            phase = .failed("Connect to the Flipper first, or select the SD card over USB.")
            return
        }
        let items = Array(allManifest.values)
        var result: [PluginUpdate] = []
        for (i, f) in items.enumerated() {
            if channel == .ble, ble().state != .ready {
                phase = .failed("Disconnected during scan")
                return
            }
            phase = .scanning(i + 1, items.count)
            let dev = await storage.md5(f.targetPath)
            if dev != f.newMD5 {
                var u = PluginUpdate(remotePath: f.remotePath, name: f.name, category: f.category,
                                     pack: f.pack, newMD5: f.newMD5, oldMD5: dev, size: f.size)
                // Differs-from-pack apps may be YOUR mods, and new pack entries can be
                // low-value duplicates. Leave both for explicit review.
                u.selected = false
                result.append(u)
            }
        }
        changedFromScan = result.filter { !$0.isNew }.count
        updates = sortUpdates(result)
        phase = updates.isEmpty ? .done("Everything up to date · \(tag)") : .idle
        await validateCompatibility()
    }

    /// First-run option B: assume the Flipper already has this build (e.g. just
    /// flashed via SD). Seeds the baseline instantly with no scan.
    func seedBaseline() {
        var map: [String: String] = [:]
        for (path, f) in allManifest { map[path] = f.newMD5 }
        saveCache(Cache(tag: tag, map: map))
        updates = []
        phase = .done("Baseline set · \(tag)")
    }

    private func ble() -> FlipperBLE { .shared }
    private var activeStorage: any DeviceFileStore { TransferChannelStore.shared.activeStore }
    var activeChannel: TransferChannel { TransferChannelStore.shared.activeChannel }

    private func fileChannelReady(_ channel: TransferChannel, timeout: Double? = nil) async -> Bool {
        switch channel {
        case .usb:
            return true
        case .ble:
            if let timeout {
                return await ble().waitUntilReady(timeout: timeout)
            }
            return await ble().waitUntilReady()
        }
    }

    // MARK: - Install

    /// Set by the Stop button. Checked at each file boundary in install(); the file
    /// currently being written always finishes and is md5-verified, so the app you
    /// pressed Stop on stays whole. Files not yet started keep their current version.
    @Published private(set) var stopRequested = false
    func requestStop() { stopRequested = true }

    func install() async {
        let requested = updates.filter(\.selected)
        guard !requested.isEmpty else { return }
        stopRequested = false
        // Mark busy immediately so the Install button disables before any
        // await point — `phase` stayed `.idle` (not busy) through the
        // fileChannelReady/prepare waits below, letting a double-tap start a
        // second, fully overlapping install() run.
        phase = .installing(0, requested.count)
        let channel = activeChannel
        let storage = activeStorage
        guard await fileChannelReady(channel) else {
            phase = .failed("Flipper isn't ready — wait for the green “Connected & ready” status, select USB SD, then retry.")
            return
        }

        // Issue #19: reject any selected FAP/FAL whose embedded `.fapmeta` is
        // incompatible with the connected firmware. Read fresh device_info and gate
        // BEFORE the first storage write below, so nothing is written for a rejected
        // binary. Non-FAP data files keep their existing MD5/routing checks.
        let (devApi, devTarget) = await deviceApiTarget()
        deviceApiMajor = devApi
        deviceTarget = devTarget
        classifications = PluginSelectionPolicy.classify(
            catalogMeta, deviceApiMajor: devApi, deviceTarget: devTarget)
        let rejected = PackageCompatibilityGate.blocked(
            fapCandidates(requested), deviceApiMajor: devApi, deviceTarget: devTarget)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: classifications)
        if !rejected.isEmpty {
            phase = .failed(PackageCompatibilityGate.summary(rejected))
            return
        }

        let selected = PluginSelectionPolicy.selectedInstallable(
            updates, classifications: classifications)
        guard !selected.isEmpty else {
            phase = .failed("No compatible apps selected.")
            return
        }

        var cache = loadCache() ?? Cache(tag: tag, map: [:])

        var installed = Set<String>()      // verified on device
        var failures: [String] = []
        var cleanedDuplicates: [String] = []   // legacy copies removed (exact pack match)
        var keptDuplicates: [String] = []      // legacy copies left for review (md5 differs)
        verifyResult = nil
        lastCleanup = nil

        let live = InstallActivityController()
        let transferReporter = TransferActivityReporter(channel: channel)
        live.start(total: selected.count)
        // Give FAB2 a moment to finish negotiating after the link reaches
        // .ready before arming the on-device indicator — closes the small
        // ready -> FAB2-negotiated gap that could otherwise drop transfer_begin
        // silently (companion issue #18). Never blocks the install either way.
        _ = await transferReporter.prepare()
        transferReporter.begin("all-the-plugins")
        defer {
            transferReporter.end()
            live.finish(installed: installed.count, total: selected.count)
        }

        let maxAttempts = 3
        for (i, u) in selected.enumerated() {
            // Stop before starting a new file: apps not yet started keep their version.
            if stopRequested { break }
            live.update(current: i + 1, total: selected.count, name: u.name)
            guard let data = extractData(remotePath: u.remotePath) else {
                failures.append("\(u.name): not found in pack"); continue
            }
            let dir = (u.targetPath as NSString).deletingLastPathComponent
            // Write the new FAP to a sibling temp first, and only swap it into place after
            // it is fully written AND md5-verified. So a Stop (or a link death) mid-write
            // just discards the temp and leaves the installed app on its previous, working
            // version — the app you stopped on is never a truncated/broken FAP.
            let tempPath = u.targetPath + ".ucnew"

            var ok = false
            var stoppedMidFile = false
            var lastReason = "unknown error"
            for attempt in 1...maxAttempts {
                phase = .installing(i + 1, selected.count)
                transferReporter.progress(u.name, force: attempt == 1)
                installDetail = InstallDetail(
                    name: u.name,
                    sent: 0,
                    total: data.count,
                    attempt: attempt,
                    channel: channel
                )

                // Re-establish the link before each try — a long install can drop
                // BLE briefly and auto-reconnect; wait for it instead of failing.
                guard await fileChannelReady(channel, timeout: attempt == 1 ? 6 : 12) else {
                    lastReason = "Flipper disconnected"
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                try? await storage.makeDirectory(dir)
                do {
                    try? await storage.delete(tempPath)      // clear any stale temp from a prior run
                    try await storage.write(tempPath, data: data) { sent in
                        Task { @MainActor in
                            if let d = self.installDetail, d.name == u.name, sent > d.sent {
                                self.installDetail?.sent = sent
                                transferReporter.progress(u.name)
                            }
                        }
                    }
                    installDetail?.sent = data.count
                    // Stop check BEFORE the live app is touched: drop the temp and keep the
                    // previous, working version in place — nothing half-written is applied.
                    if stopRequested { try? await storage.delete(tempPath); stoppedMidFile = true; break }
                    // Verify the staged temp, then swap it into place. storage.move is a
                    // device-side rename (no BLE transfer), so the commit is quick and the
                    // long, interruptible part (the BLE write) already went to the temp.
                    let staged = await verifyWrite(
                        path: tempPath, expectedMD5: u.newMD5, expectedSize: data.count, storage: storage)
                    guard staged.ok else { lastReason = staged.reason; try? await storage.delete(tempPath); continue }
                    if await storage.exists(u.targetPath) { try? await storage.delete(u.targetPath) }
                    try await storage.move(tempPath, to: u.targetPath)
                    let landed = await verifyWrite(
                        path: u.targetPath, expectedMD5: u.newMD5, expectedSize: data.count, storage: storage)
                    if landed.ok { ok = true; break }
                    lastReason = landed.reason
                } catch {
                    lastReason = error.localizedDescription
                    ulog.error("install \(u.name, privacy: .public) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                    try? await storage.delete(tempPath)      // never leave a partial temp behind
                    try? await Task.sleep(nanoseconds: 800_000_000)   // let reconnect engage
                }
            }

            if ok {
                installed.insert(u.remotePath)
                cache.map[u.remotePath] = u.newMD5
                history.insert(InstallRecord(date: Date(), tag: tag, name: u.name,
                                             pack: u.pack, wasNew: u.isNew), at: 0)

                // Legacy-duplicate sweep for a routed app: the new copy is now verified at
                // u.targetPath, so a stale pre-routing copy may linger at u.remotePath.
                // Remove it ONLY when it byte-matches what we just installed (md5 ==
                // newMD5); if it differs it may be your custom/older build — keep it.
                if u.isRouted, u.remotePath != u.targetPath,
                   let legacyMD5 = await storage.md5(u.remotePath) {
                    if legacyMD5 == u.newMD5 {
                        do {
                            try await storage.delete(u.remotePath, recursive: false)
                            cleanedDuplicates.append(u.remotePath)
                            ulog.notice("removed legacy duplicate \(u.remotePath, privacy: .public)")
                        } catch {
                            keptDuplicates.append(u.remotePath)   // couldn't delete → leave it
                            ulog.error("failed to remove legacy duplicate \(u.remotePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    } else {
                        keptDuplicates.append(u.remotePath)
                        ulog.notice("kept legacy file for review (md5 differs) \(u.remotePath, privacy: .public)")
                    }
                }
            } else if !stoppedMidFile {
                failures.append("\(u.name): \(lastReason)")
            }
            // Stopped mid-file: the temp was discarded and the live app kept its previous
            // working version — it's neither installed nor failed. End the run here.
            if stopRequested { break }
        }
        installDetail = nil
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        saveHistory()

        // Reconcile cache: unchanged apps + verified installs = new md5. Failed /
        // skipped stay at their old value so they surface again next check.
        let inUpdates = Set(updates.map(\.remotePath))
        for (path, f) in allManifest where !inUpdates.contains(path) || installed.contains(path) {
            cache.map[path] = f.newMD5
        }
        cache.tag = tag
        saveCache(cache)

        // Keep failed/skipped in the list; drop only the verified ones.
        updates.removeAll { installed.contains($0.remotePath) }

        // Post-install signature summary: each install above is md5-verified on the
        // device, so this records exactly what landed intact vs what didn't.
        verifyResult = VerifyResult(kind: .postInstall, tag: tag,
                                    verified: installed.count, failed: failures)
        lastCleanup = (cleanedDuplicates.isEmpty && keptDuplicates.isEmpty)
            ? nil : CleanupResult(removed: cleanedDuplicates, kept: keptDuplicates)

        let cleanNote = cleanedDuplicates.isEmpty ? "" : " · cleaned \(cleanedDuplicates.count) duplicate\(cleanedDuplicates.count == 1 ? "" : "s")"
        if stopRequested {
            // Files that were stopped (mid-temp-write or not yet started) kept their
            // previous working version — neither installed nor failed. Any genuine
            // failure (e.g. a verify mismatch) is still surfaced separately.
            let kept = max(0, selected.count - installed.count - failures.count)
            var msg = "Stopped — installed \(installed.count) of \(selected.count)\(cleanNote)."
            if kept > 0 { msg += " \(kept) kept their current version." }
            if failures.isEmpty {
                phase = .done(msg)
            } else {
                msg += " \(failures.count) failed and may need reinstalling: "
                    + failures.prefix(3).joined(separator: "; ") + (failures.count > 3 ? " …" : "")
                phase = .failed(msg)
            }
        } else if failures.isEmpty {
            phase = .done("Installed \(installed.count) app\(installed.count == 1 ? "" : "s")\(cleanNote) · \(tag)")
        } else {
            let head = installed.isEmpty ? "Install failed" : "Installed \(installed.count), \(failures.count) failed"
            phase = .failed("\(head)\(cleanNote): " + failures.prefix(4).joined(separator: "; ")
                            + (failures.count > 4 ? " …" : ""))
        }
    }

    /// On-demand signature check — the all-the-plugins analogue of FW packages'
    /// "Verify on device". Re-hashes every .fap in the current pack on the Flipper and
    /// compares to the expected md5; files that are missing or whose md5 differs are
    /// surfaced as selectable updates so the existing Install button can (re)install them.
    /// Heavy over BLE (one md5 round-trip per file); fast over USB SD.
    func verifyInstalled() async {
        guard !allManifest.isEmpty else {
            phase = .failed("Run “Check for updates” first so the pack manifest is loaded.")
            return
        }
        let channel = activeChannel
        guard await fileChannelReady(channel) else {
            phase = .failed("Connect to the Flipper first, or select the SD card over USB.")
            return
        }
        let storage = activeStorage
        verifyResult = nil
        let items = allManifest.values.sorted { $0.remotePath < $1.remotePath }
        var bad: [PluginUpdate] = []
        var failures: [String] = []
        var verified = 0
        for (i, f) in items.enumerated() {
            if Task.isCancelled { phase = .idle; return }
            phase = .verifying(i + 1, items.count)
            guard await fileChannelReady(channel) else { phase = .failed("Disconnected during verify"); return }
            let dev = await storage.md5(f.targetPath)
            if dev == f.newMD5 {
                verified += 1
            } else {
                var update = PluginUpdate(
                    remotePath: f.remotePath,
                    name: f.name,
                    category: f.category,
                    pack: f.pack,
                    newMD5: f.newMD5,
                    oldMD5: dev,
                    size: f.size)
                update.selected = dev != nil
                bad.append(update)
                failures.append("\(f.name): \(dev == nil ? "missing" : "md5 mismatch")")
            }
        }
        verifyResult = VerifyResult(kind: .onDevice, tag: tag, verified: verified, failed: failures)
        await refreshProtectedReviews()
        if bad.isEmpty {
            phase = .done("Verified \(verified) app\(verified == 1 ? "" : "s") on device · all match \(tag)")
        } else {
            updates = sortUpdates(bad)   // surface missing/mismatched for one-tap reinstall
            phase = .idle
        }
        await validateCompatibility()
    }

    /// Verify a freshly-written file. Retries the md5 once after a short pause
    /// (slow SD flush), then — if still wrong — reports device vs source size so
    /// a truncated write (dropped chunk) is distinguishable from byte corruption.
    private func verifyWrite(
        path: String,
        expectedMD5: String,
        expectedSize: Int,
        storage: any DeviceFileStore
    ) async -> (ok: Bool, reason: String) {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            if let dev = await storage.md5(path), dev == expectedMD5 { return (true, "") }
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let devSize = (try? await storage.list(dir))?.first { $0.name == name }?.size
        let sizeStr = devSize.map { "\($0)" } ?? "missing"
        return (false, "md5 mismatch (device \(sizeStr)B vs source \(expectedSize)B)")
    }

    // MARK: - GitHub

    /// Picks the release to use: the manual pin if one is set, otherwise GitHub's own
    /// "latest" (most recently published non-draft, non-prerelease release).
    private func latestRelease() async throws -> (String, [String: URL]) {
        let path = manualReleaseTag.map { "releases/tags/\($0)" } ?? "releases/latest"
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            throw NSError(domain: "updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub API unavailable (rate limit?)"])
        }
        var map: [String: URL] = [:]
        for a in assets {
            if let name = a["name"] as? String, let u = a["browser_download_url"] as? String,
               let url = URL(string: u) { map[name] = url }
        }
        return (tag, map)
    }

    /// Fetches recent releases for the manual picker — newest first, capped at 20 (far
    /// more than anyone needs to page back through, and one request instead of paginating).
    func loadAvailableReleases() async {
        loadingReleases = true
        defer { loadingReleases = false }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        let formatter = ISO8601DateFormatter()
        availableReleases = arr.compactMap { r -> PluginReleaseInfo? in
            guard let tag = r["tag_name"] as? String,
                  let publishedRaw = r["published_at"] as? String,
                  let published = formatter.date(from: publishedRaw),
                  r["draft"] as? Bool != true, r["prerelease"] as? Bool != true else { return nil }
            let assetNames = Set((r["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            let hasPacks = assetNames.contains("all-the-apps-base.zip") && assetNames.contains("all-the-apps-extra.zip")
            return PluginReleaseInfo(tag: tag, publishedAt: published, hasPacks: hasPacks)
        }
    }

    /// Pins the pack source to an exact release (nil = back to Auto/latest) and
    /// re-checks immediately so the switch is reflected right away.
    func setManualReleaseTag(_ tag: String?) {
        manualReleaseTag = tag
        Self.saveManualReleaseTag(tag)
        Task { await check() }
    }

    private static let manualReleaseTagKey = "pluginManualReleaseTag"
    private static func loadManualReleaseTag() -> String? {
        UserDefaults.standard.string(forKey: manualReleaseTagKey)
    }
    private static func saveManualReleaseTag(_ tag: String?) {
        if let tag { UserDefaults.standard.set(tag, forKey: manualReleaseTagKey) }
        else { UserDefaults.standard.removeObject(forKey: manualReleaseTagKey) }
    }

    private func download(_ url: URL, to name: String) async throws -> URL {
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Zip

    private struct ExtractedPack {
        var updates: [PluginUpdate] = []
        var metadata: [String: PluginCatalogMetadata] = [:]
    }

    private func extractManifest(zipURL: URL, pack: String) throws -> ExtractedPack {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw NSError(domain: "updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad \(pack) zip"])
        }
        var out = ExtractedPack()
        for entry in archive where FapCompatibility.isBinary(entry.path) {
            guard let rp = PluginInstallRouting.remotePath(for: entry.path) else { continue }
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let comps = rp.split(separator: "/")
            let name = (String(comps.last ?? "") as NSString).deletingPathExtension
            let category = comps.count >= 2 ? String(comps[comps.count - 2]) : ""
            out.updates.append(PluginUpdate(
                remotePath: rp,
                name: name,
                category: category,
                pack: pack,
                newMD5: md5,
                oldMD5: nil,
                size: data.count))
            out.metadata[rp] = FapMetadata.parse(data).map(PluginCatalogMetadata.parsed) ?? .invalid
        }
        return out
    }

    private func extractData(remotePath: String) -> Data? {
        for (_, url) in packURLs {
            guard let archive = Archive(url: url, accessMode: .read) else { continue }
            for entry in archive where FapCompatibility.isBinary(entry.path) {
                if PluginInstallRouting.remotePath(for: entry.path) == remotePath {
                    var data = Data()
                    _ = try? archive.extract(entry) { data.append($0) }
                    if !data.isEmpty { return data }
                }
            }
        }
        return nil
    }

    // MARK: - Cache

    private func loadCache() -> Cache? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: d)
    }
    private func saveCache(_ c: Cache) {
        if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: cacheKey) }
    }
    func resetBaseline() { UserDefaults.standard.removeObject(forKey: cacheKey) }

    // MARK: - Exclusions (protect locally-modified apps)

    private static func loadExcluded() -> Set<String> {
        if let arr = UserDefaults.standard.array(forKey: excludedKey) as? [String] {
            let original = Set(arr.map { $0.lowercased() })
            let saved = original.subtracting(retiredBuiltInExcluded)
            let merged = saved.union(builtInExcluded)
            if merged != original {
                UserDefaults.standard.set(Array(merged).sorted(), forKey: excludedKey)
            }
            return merged
        }
        return builtInExcluded
    }
    private func saveExcluded() {
        UserDefaults.standard.set(Array(excluded), forKey: Self.excludedKey)
    }
    private static let unprotectedKey = "pluginUnprotectedBuiltIns"
    private static func loadUnprotected() -> Set<String> {
        guard let arr = UserDefaults.standard.array(forKey: unprotectedKey) as? [String] else { return [] }
        return Set(arr.map { $0.lowercased() }).intersection(builtInExcluded)   // only honor real built-ins
    }
    private func saveUnprotected() {
        UserDefaults.standard.set(Array(unprotectedBuiltIns).sorted(), forKey: Self.unprotectedKey)
    }
    func addExclusion(_ name: String) {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".fap", with: "")
        guard !n.isEmpty else { return }
        excluded.insert(n)
        unprotectedBuiltIns.remove(n)   // re-protecting a built-in clears its override
        saveExcluded(); saveUnprotected()
        updates.removeAll { $0.name.lowercased() == n }   // drop it from the current list
    }
    func removeExclusion(_ name: String) {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ".fap", with: "")
        if Self.builtInExcluded.contains(n) {
            // Built-ins are re-merged into `excluded` on load, so we lift protection with
            // an explicit override instead of removing them. Re-protect via addExclusion.
            unprotectedBuiltIns.insert(n); saveUnprotected()
        } else {
            excluded.remove(n); saveExcluded()
        }
    }

    // MARK: - History

    private static let historyKey = "pluginHistory"
    private static func loadHistory() -> [InstallRecord] {
        guard let d = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([InstallRecord].self, from: d)) ?? []
    }
    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(d, forKey: Self.historyKey)
        }
    }
    func clearHistory() { history = []; saveHistory() }
}
