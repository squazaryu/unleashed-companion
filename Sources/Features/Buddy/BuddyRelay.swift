import Foundation
import Combine

/// Full-duplex Claude Buddy passthrough — now self-arming.
///
/// The real `claude_buddy.fap` speaks newline-JSON over the Flipper's standard BLE
/// serial characteristics — the SAME ones this app uses for RPC. The two can't share
/// the channel, so passthrough pauses RPC. But pausing RPC must happen ONLY while the
/// Buddy app is actually the active serial peer — otherwise leaving the toggle on
/// would kill Device/Files/View (RPC) and spray the daemon's pings into the Flipper's
/// RPC parser (periodic disconnects).
///
/// So: when enabled, we listen to the serial stream and detect Buddy frames
/// (`{"v":…}`). Seeing them ⇒ the fap is foreground ⇒ arm passthrough (RPC off, pipe
/// both ways). Once the stream goes quiet for `activeWindow` ⇒ disarm (RPC resumes).
/// While disarmed the channel is left entirely to RPC and nothing is written to it.
///
///   Flipper TX (buttons)  → ble.serialIn → POST /buddy/up   → daemon → keystrokes
///   daemon (notify/menu)  → GET /buddy/down → ble.writeSerialRaw → Flipper RX → screen
@MainActor
final class BuddyRelay: ObservableObject {
    static let shared = BuddyRelay()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "buddyEnabled")
            if enabled { start() } else { stop() }
        }
    }
    @Published private(set) var lastEvent: String?
    @Published private(set) var active = false       // true while the Buddy .fap is the live peer
    @Published private(set) var bytesDown = 0
    @Published private(set) var bytesUp = 0

    private let ble = FlipperBLE.shared
    private var downTimer: Timer?
    private var uplink: AnyCancellable?
    private var lastBuddySeen: Date?
    private let activeWindow: TimeInterval = 6        // disarm after this much silence

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "buddyEnabled")
    }

    func startIfEnabled() { if enabled { start() } }

    private func base() -> String { UserDefaults.standard.string(forKey: "aiRadarBridgeURL") ?? "" }

    private func start() {
        stop(resetState: false)
        // Listen but DON'T pause RPC yet — only when the fap actually starts talking.
        uplink = ble.serialIn.sink { [weak self] data in
            Task { @MainActor in self?.onSerial(data) }
        }
        downTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func stop(resetState: Bool = true) {
        downTimer?.invalidate(); downTimer = nil
        uplink?.cancel(); uplink = nil
        disarm()
        if resetState { lastBuddySeen = nil }
    }

    /// A serial frame from the Flipper. If it's Buddy JSON, the fap is foreground →
    /// arm passthrough and forward it. RPC traffic (when disarmed) is ignored here.
    private func onSerial(_ data: Data) {
        guard enabled else { return }
        if looksLikeBuddy(data) {
            lastBuddySeen = Date()
            if !active { arm() }
        }
        guard active else { return }          // disarmed → it's RPC, not ours
        Task { await post("/buddy/up", body: data) }
        bytesUp += data.count
    }

    private func tick() async {
        // Disarm once the fap stops talking, handing the channel back to RPC.
        if active, let last = lastBuddySeen, Date().timeIntervalSince(last) > activeWindow {
            disarm()
            return
        }
        guard active, ble.state == .ready,
              let url = AIRadarBridgeClient.relayURL(from: base(), path: "/buddy/down") else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
        ble.writeSerialRaw(data)              // credit-free; only ever while armed
        bytesDown += data.count
        if let label = Self.describe(data) { lastEvent = label }
    }

    private func arm() {
        active = true
        ble.buddyMode = true                  // pause RPC: the fap owns the serial channel
        Task { await post("/buddy/reset", body: nil) }   // drop stale bytes both ends
    }

    private func disarm() {
        active = false
        ble.buddyMode = false                 // hand the serial channel back to RPC
    }

    private func looksLikeBuddy(_ data: Data) -> Bool {
        // Buddy frames are newline-JSON beginning {"v":1,… — a sequence RPC protobuf
        // never carries as ASCII.
        guard let s = String(data: data, encoding: .utf8) else { return false }
        return s.contains("{\"v\":")
    }

    private func post(_ path: String, body: Data?) async {
        guard let url = AIRadarBridgeClient.relayURL(from: base(), path: path) else { return }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        if let body { req.httpBody = body; req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        _ = try? await URLSession.shared.data(for: req)
    }

    private static func describe(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        for line in s.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = obj["t"] as? String else { continue }
            let payload = obj["d"] as? [String: Any]
            let text = (payload?["text"] as? String) ?? ""
            if t == "notify" || t == "status" { return text.isEmpty ? t : text }
        }
        return nil
    }
}
