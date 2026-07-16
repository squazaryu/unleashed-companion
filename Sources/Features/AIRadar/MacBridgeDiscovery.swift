import Foundation

/// Finds the Mac AI Radar Bridge on the local network via Bonjour, so the phone
/// doesn't need a hardcoded IP (the Mac's DHCP IP changes; the resolved
/// `<host>.local` name survives that).
final class MacBridgeDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = MacBridgeDiscovery()

    @Published private(set) var discoveredBase: String?   // e.g. "http://macbook.local:8730"
    @Published private(set) var discoveredHost: String?

    private let browser = NetServiceBrowser()
    private var resolving: Set<NetService> = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        browser.delegate = self
        browser.searchForServices(ofType: "_airadar._tcp", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { resolving.remove(service) }
        guard var host = service.hostName, service.port > 0 else { return }
        if host.hasSuffix(".") { host.removeLast() }     // strip trailing dot
        let base = "http://\(host):\(service.port)"
        UserDefaults.standard.set(base, forKey: "aiRadarDiscoveredBase")   // thread-safe fallback
        DispatchQueue.main.async {
            self.discoveredHost = host
            self.discoveredBase = base
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async {
            if self.discoveredHost == service.hostName?.replacingOccurrences(of: ".", with: "") {
                // best-effort; keep last known otherwise
            }
        }
    }
}
