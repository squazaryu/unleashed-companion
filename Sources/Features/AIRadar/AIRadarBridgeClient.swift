import Foundation

/// Shared helpers for talking to the Mac AI Radar Bridge and relaying its usage
/// snapshot to the Flipper. Used by both the AI Radar screen and the background
/// relay that answers the Flipper's "refresh" button.
enum AIRadarBridgeClient {
    static let appID = "ai_dashboard"              // matches AI_DASHBOARD_APP_ID on the Flipper
    static let endMarker = "\n<<<END>>>\n"         // ai_dashboard_ble_end_marker
    static let usageDir = "/ext/apps_data/ai_dashboard"
    static var usagePath: String { usageDir + "/usage.txt" }

    /// Normalise "host:port" / full URL into a usage.txt URL. If the user left the
    /// field empty, fall back to the Bonjour-discovered Mac bridge.
    static func usageURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = UserDefaults.standard.string(forKey: "aiRadarDiscoveredBase") ?? "" }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard var c = URLComponents(string: s) else { return nil }
        if c.path.isEmpty || c.path == "/" { c.path = "/usage.txt" }
        return c.url
    }

    /// The Mac bridge's /buddy endpoint (Claude Buddy notification queue).
    static func buddyURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = UserDefaults.standard.string(forKey: "aiRadarDiscoveredBase") ?? "" }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard var c = URLComponents(string: s) else { return nil }
        c.path = "/buddy"; c.query = nil
        return c.url
    }

    /// A path on the Mac bridge (e.g. "/buddy/down", "/buddy/up", "/buddy/reset")
    /// — used by the full-duplex Buddy serial passthrough.
    static func relayURL(from raw: String, path: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = UserDefaults.standard.string(forKey: "aiRadarDiscoveredBase") ?? "" }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard var c = URLComponents(string: s) else { return nil }
        c.path = path; c.query = nil
        return c.url
    }

    static func fetch(_ url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Stream the snapshot to a RUNNING Flipper AI Dashboard app via the App Bridge
    /// (its receive path accumulates payload until the end marker), so the on-device
    /// screen updates live. Payload frames are capped at 172 bytes and paced.
    static func pushViaAppBridge(_ text: String, ble: FlipperBLE) async {
        let bytes = Array((text + endMarker).utf8)
        let chunk = 160
        var i = 0
        while i < bytes.count {
            let end = min(i + chunk, bytes.count)
            ble.sendAppBridge(appID: appID, command: "data", payload: Data(bytes[i..<end]))
            i = end
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// Persist usage.txt on the Flipper so the app shows it on next launch too.
    static func persist(_ text: String, storage: FlipperStorage) async {
        try? await storage.makeDirectory(usageDir)
        try? await storage.write(usagePath, data: Data(text.utf8))
    }
}
