import Foundation

/// Pure, testable helpers for turning a resolved `_home-assistant._tcp` service
/// into a base URL. Kept free of NetService so it can be unit-tested.
enum HABonjour {
    /// Home Assistant's zeroconf TXT record carries `base_url` / `internal_url`
    /// (and on newer cores `internal_url`), plus `version`, `uuid`,
    /// `location_name`. We only read it to learn the *scheme* (http vs https);
    /// the host + port come from the SRV/A records so the result tracks the
    /// Mac's current DHCP lease instead of a URL the user may have pinned to a
    /// stale IP.
    static func scheme(fromTXT txt: [String: Data]) -> String {
        for key in ["internal_url", "base_url", "external_url"] {
            if let raw = txt[key], let s = String(data: raw, encoding: .utf8),
               s.lowercased().hasPrefix("https") {
                return "https"
            }
        }
        return "http"
    }

    /// Build the base from the resolved host + port. Returns nil for unusable
    /// input (empty host / non-positive port) so the caller can skip it.
    static func base(host rawHost: String, port: Int, txt: [String: Data]) -> String? {
        var host = rawHost
        if host.hasSuffix(".") { host.removeLast() }   // strip the trailing mDNS dot
        guard !host.isEmpty, port > 0 else { return nil }
        return "\(scheme(fromTXT: txt))://\(host):\(port)"
    }
}

/// Finds Home Assistant on the local network via its native Bonjour
/// advertisement (`_home-assistant._tcp`), so the Relay doesn't need a
/// hardcoded LAN IP. HA runs on a DHCP lease; the resolved `<host>.local` name
/// survives a lease change where a pinned `http://192.168.x.y:8123` would break.
///
/// Mirrors ``MacBridgeDiscovery`` (the `_airadar._tcp` browser) — same
/// singleton + UserDefaults-fallback shape, so ``RelayExecutor`` can read the
/// last-discovered base off the main actor.
final class HomeAssistantDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = HomeAssistantDiscovery()

    /// UserDefaults key holding the last-discovered base, e.g.
    /// "http://homeassistant.local:8123". Read by ``RelayExecutor`` when the
    /// user hasn't pinned a URL.
    static let defaultsKey = "haDiscoveredBase"

    @Published private(set) var discoveredBase: String?
    @Published private(set) var discoveredHost: String?

    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.searchForServices(ofType: "_home-assistant._tcp", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { resolving.remove(service) }
        guard let host = service.hostName else { return }
        let txt = service.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
        guard let base = HABonjour.base(host: host, port: service.port, txt: txt) else { return }
        var cleanHost = host
        if cleanHost.hasSuffix(".") { cleanHost.removeLast() }
        UserDefaults.standard.set(base, forKey: Self.defaultsKey)   // thread-safe fallback for RelayExecutor
        DispatchQueue.main.async {
            self.discoveredHost = cleanHost
            self.discoveredBase = base
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        // Keep the last-known base; a HA that briefly drops off mDNS shouldn't wipe
        // the Relay's fallback mid-session.
    }
}
