import Foundation
import Combine
import os
import WidgetKit
import UnleashedShared

private let rlog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "relay")

struct RelayLogEntry: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let text: String
    let ok: Bool
}

enum RelayPath: String, CaseIterable, Identifiable {
    case auto      // HA first, fail over to Sber cloud
    case sberOnly  // direct Sber cloud only
    case haOnly    // Home Assistant only
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:     return "Auto (HA → Sber)"
        case .sberOnly: return "Sber cloud only"
        case .haOnly:   return "Home Assistant only"
        }
    }
}

/// Executor side of the FlipperRelay chain — the role the Mac's `relay_bridge.py`
/// used to play, now on the phone. Listens for App Bridge events from the
/// Flipper and actuates the relay.
///
/// Failsafe so the Mac is not required:
///   • Auto: try the local HA webhook (short timeout); if HA is unreachable,
///     the phone talks DIRECTLY to the Sber cloud (no Mac/HA needed).
@MainActor
final class RelayExecutor: ObservableObject {
    @Published var haBaseURL: String {
        didSet { UserDefaults.standard.set(haBaseURL, forKey: "haBaseURL") }
    }

    /// The HA base URL to actually hit. Priority:
    ///   1. the URL the user pinned in settings (`haBaseURL`), if non-empty;
    ///   2. the Bonjour-discovered base — tracks HA's current DHCP lease;
    ///   3. the mDNS default name as a last resort.
    /// Pure static so the priority logic is unit-testable without the BLE-wired init.
    nonisolated static func resolveBase(typed: String, discovered: String?) -> String {
        let t = typed.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if let d = discovered?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        return "http://homeassistant.local:8123"
    }

    /// Resolved base for the current call: pinned URL, else last Bonjour hit, else mDNS name.
    var effectiveHABase: String {
        Self.resolveBase(typed: haBaseURL,
                         discovered: UserDefaults.standard.string(forKey: HomeAssistantDiscovery.defaultsKey))
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "relayEnabled") }
    }
    @Published var path: RelayPath {
        didSet { UserDefaults.standard.set(path.rawValue, forKey: "relayPath") }
    }
    @Published var deviceID: String {
        didSet { UserDefaults.standard.set(deviceID, forKey: "sberDeviceID") }
    }
    /// Optional HA long-lived token + entity to READ the relay's current state
    /// (the webhook is fire-only, so state needs the REST API).
    @Published var haToken: String {
        didSet { UserDefaults.standard.set(haToken, forKey: "haToken") }
    }
    @Published var haEntityID: String {
        didSet { UserDefaults.standard.set(haEntityID, forKey: "haEntityID") }
    }
    /// Last commanded relay state, persisted across launches. The Sber relay does
    /// not report a reliable *steady* state to HA (switch.rele_1 reverts to off a
    /// couple seconds after an on command; the template switch sticks), so the only
    /// trustworthy "is it on" is what we last commanded — from the app or the Flipper.
    @Published private(set) var relayState: Bool? {   // nil = never commanded yet
        didSet {
            let d = UserDefaults.standard
            if let s = relayState { d.set(s, forKey: "relayLastState") }
            else { d.removeObject(forKey: "relayLastState") }
            SharedStore.saveRelay(.init(on: relayState, updated: Date()))
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    @Published private(set) var stateError: String? // diagnostic from a manual HA read
    @Published private(set) var hasSberToken = false
    @Published private(set) var log: [RelayLogEntry] = []

    static let sberActions: Set<String> = ["on", "off", "toggle"]
    private let haTimeoutAuto: TimeInterval = 2.5
    private var cancellable: AnyCancellable?

    init() {
        // Empty by default → the Relay auto-discovers HA over Bonjour
        // (_home-assistant._tcp). `effectiveHABase` resolves empty to the
        // discovered host, then the mDNS name as a last resort. Users who pinned
        // a URL in an earlier build keep it (it's already in UserDefaults).
        self.haBaseURL = UserDefaults.standard.string(forKey: "haBaseURL") ?? ""
        self.enabled = UserDefaults.standard.object(forKey: "relayEnabled") as? Bool ?? true
        self.path = RelayPath(rawValue: UserDefaults.standard.string(forKey: "relayPath") ?? "") ?? .auto
        self.deviceID = UserDefaults.standard.string(forKey: "sberDeviceID") ?? SberAPI.defaultDeviceID
        self.haToken = UserDefaults.standard.string(forKey: "haToken") ?? ""
        self.haEntityID = UserDefaults.standard.string(forKey: "haEntityID") ?? ""
        self.relayState = UserDefaults.standard.object(forKey: "relayLastState") as? Bool

        cancellable = FlipperBLE.shared.appBridgeIn
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in self?.handle(frame) }

        Task { await refreshTokenStatus() }
    }

    // MARK: - Token management (UI)

    func importSberToken(_ json: String) {
        Task {
            do {
                try await SberCloudClient.shared.importToken(json: json)
                await refreshTokenStatus()
                append("Sber token imported", ok: true)
            } catch {
                append("Sber token import failed: \(error.localizedDescription)", ok: false)
            }
        }
    }

    func clearSberToken() {
        Task { await SberCloudClient.shared.clearToken(); await refreshTokenStatus() }
    }

    /// Called after the in-app Sber login saved a token.
    func sberLoginSucceeded() {
        Task { await refreshTokenStatus(); append("Sber login OK — token saved", ok: true) }
    }

    private func refreshTokenStatus() async {
        let has = await SberCloudClient.shared.hasToken
        await MainActor.run { self.hasSberToken = has }
    }

    // MARK: - Incoming Flipper events

    private func handle(_ frame: AppBridgeFrame) {
        rlog.notice("appbridge IN \(frame.appID, privacy: .public)/\(frame.command, privacy: .public)")
        guard enabled else {
            append("ignored (executor off): \(frame.appID)/\(frame.command)", ok: false)
            return
        }
        switch frame.appID {
        case "sber_relay" where Self.sberActions.contains(frame.command):
            Task { await self.actuate(action: frame.command) }
        default:
            append("no mapping: \(frame.appID)/\(frame.command)", ok: false)
        }
    }

    /// Used by the on-screen test buttons.
    func test(action: String) { Task { await actuate(action: action) } }

    // MARK: - Failsafe actuation

    private func actuate(action: String) async {
        // The relay doesn't report a reliable steady state, so the command itself IS
        // the source of truth: set + persist the pill here (covers both the on-screen
        // buttons and Flipper App Bridge events). No HA read-back to override it.
        switch action {
        case "on": relayState = true
        case "off": relayState = false
        case "toggle": relayState = relayState.map { !$0 } ?? true
        default: break
        }
        switch path {
        case .haOnly:
            await fireHA(action: action, timeout: 8, label: "HA")
        case .sberOnly:
            await fireSber(action: action, label: "Sber")
        case .auto:
            let ok = await fireHA(action: action, timeout: haTimeoutAuto, label: "HA")
            if !ok {
                append("HA unavailable → failover to Sber cloud", ok: false)
                await fireSber(action: action, label: "Sber (failsafe)")
            }
        }
    }

    @discardableResult
    private func fireHA(action: String, timeout: TimeInterval, label: String) async -> Bool {
        let base = effectiveHABase
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty,
              let url = URL(string: "\(base)/api/webhook/flipper_sber_relay_\(action)") else {
            append("\(label): bad URL", ok: false); return false
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["source": "flipper", "action": action])
        rlog.notice("fire HA \(url.absoluteString, privacy: .public)")
        // Up to 2 attempts: the first call to homeassistant.local often loses a cold
        // mDNS/DNS resolve within the short auto timeout — the warm retry then lands.
        // This is the "command doesn't work the first time" fix.
        for attempt in 0..<2 {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let ok = (200...299).contains(code)
                append("\(label) \(action) → \(code)\(attempt > 0 ? " (retry)" : "")", ok: ok)
                return ok
            } catch {
                let transient = (error as? URLError).map {
                    [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost,
                     .networkConnectionLost, .dnsLookupFailed].contains($0.code)
                } ?? false
                if attempt == 0 && transient {
                    req.timeoutInterval = max(timeout, 6)   // warm retry, more patient
                    continue
                }
                rlog.error("HA error \(error.localizedDescription, privacy: .public)")
                append("\(label) \(action) → \(error.localizedDescription)", ok: false)
                return false
            }
        }
        return false
    }

    // MARK: - State (read the relay's current on/off via HA REST API)

    func refreshState() async {
        let base = effectiveHABase
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let entity = haEntityID.trimmingCharacters(in: .whitespaces)
        let token = haToken.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !entity.isEmpty, !token.isEmpty,
              let url = URL(string: "\(base)/api/states/\(entity)") else {
            stateError = "Add an HA token + entity id below to show state."
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Up to 2 attempts — the first hit to homeassistant.local often loses a cold
        // mDNS/DNS resolve within the timeout (same root cause as the command path).
        for attempt in 0..<2 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    stateError = code == 401 ? "401 — bad HA token"
                               : code == 404 ? "404 — entity ‘\(entity)’ not found"
                               : "HA returned \(code)"
                    return
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let st = (obj["state"] as? String)?.lowercased() else {
                    stateError = "Couldn’t parse HA state."; return
                }
                // Diagnostic only — do NOT drive the pill. This relay's HA state is
                // unreliable (sberdevices reverts to off; the template sticks), so the
                // pill follows the last command instead. Just report what HA returned.
                append("HA state read: \(entity) = \(st)", ok: st == "on" || st == "off")
                stateError = "HA reports ‘\(st)’ — pill follows your last command"
                return
            } catch {
                let transient = (error as? URLError).map {
                    [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost,
                     .networkConnectionLost, .dnsLookupFailed].contains($0.code)
                } ?? false
                if attempt == 0 && transient { req.timeoutInterval = 8; continue }
                rlog.error("HA state error \(error.localizedDescription, privacy: .public)")
                stateError = error.localizedDescription
                return
            }
        }
    }

    @discardableResult
    private func fireSber(action: String, label: String) async -> Bool {
        let dev = deviceID.trimmingCharacters(in: .whitespaces)
        guard !dev.isEmpty else {
            // Empty id → request hits /devices//state → 405. Fail clearly instead.
            append("\(label): set your Sber device_id in Bridge settings first", ok: false)
            return false
        }
        SberTrustDiag.shared.reset()
        do {
            try await SberCloudClient.shared.apply(action: action, deviceID: dev)
            append("\(label) \(action) → OK (relay)", ok: true)
            return true
        } catch {
            rlog.error("Sber error \(error.localizedDescription, privacy: .public)")
            append("\(label) \(action) → \(error.localizedDescription)", ok: false)
            // Trust steps that say "OK" are successes — colour them by their own result.
            for line in SberTrustDiag.shared.history {
                append("· \(line)", ok: line.localizedCaseInsensitiveContains(": ok"))
            }
            return false
        }
    }

    private func append(_ text: String, ok: Bool) {
        log.insert(RelayLogEntry(time: Date(), text: text, ok: ok), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }
}
