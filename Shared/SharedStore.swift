import Foundation

/// Cross-process snapshot the app writes and the home-screen widgets read, via the
/// shared App Group container. Pure Foundation — no WidgetKit import here so both the
/// app and the extension can link it; the app triggers widget reloads itself.
public enum SharedStore {
    /// The app group declared in project.yml. Sideload re-signers (Feather / AltStore)
    /// frequently REWRITE this id (e.g. prefix it with the signing team), which would
    /// leave the app and the widget on different containers. `appGroup` resolves the
    /// group actually present in our embedded provisioning profile so both processes
    /// agree on the same container regardless of how it was re-signed.
    public static let declaredGroup = "group.com.tumoflip.unleashedcompanion"
    public static let appGroup: String = resolveAppGroup()

    /// Is the resolved app group actually usable (entitled + container exists)? If false,
    /// the widgets can't read anything — usually a sideload signing issue.
    public static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    private static func resolveAppGroup() -> String {
        // Parse the XML plist embedded in our own provisioning profile and read the
        // app groups it was signed with. Prefer the declared id; else the first group
        // that looks like an app group.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .ascii),
              let start = raw.range(of: "<?xml"),
              let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any],
              let groups = ent["com.apple.security.application-groups"] as? [String],
              !groups.isEmpty
        else { return declaredGroup }
        return groups.first { $0 == declaredGroup }
            ?? groups.first { $0.hasPrefix("group.") || $0.contains(".group.") }
            ?? groups[0]
    }

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: - Flipper status
    public struct FlipperStatus: Codable, Equatable {
        public var connected: Bool
        public var battery: Int?
        public var firmware: String
        public var name: String
        public var updated: Date
        public init(connected: Bool, battery: Int?, firmware: String, name: String, updated: Date) {
            self.connected = connected; self.battery = battery
            self.firmware = firmware; self.name = name; self.updated = updated
        }
    }
    public static func saveFlipper(_ s: FlipperStatus) { write("flipper", s) }
    public static func flipper() -> FlipperStatus? { read("flipper") }

    // MARK: - AI Radar
    public struct RadarProvider: Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var icon: String
        public var shortLabel: String
        public var shortUsed: Int
        public var shortReset: String
        public var weeklyUsed: Int
        public init(id: String, name: String, icon: String, shortLabel: String,
                    shortUsed: Int, shortReset: String, weeklyUsed: Int) {
            self.id = id; self.name = name; self.icon = icon
            self.shortLabel = shortLabel; self.shortUsed = shortUsed
            self.shortReset = shortReset; self.weeklyUsed = weeklyUsed
        }
    }
    public struct RadarSnapshot: Codable, Equatable {
        public var providers: [RadarProvider]
        public var updatedAt: String
        public init(providers: [RadarProvider], updatedAt: String) {
            self.providers = providers; self.updatedAt = updatedAt
        }
    }
    public static func saveRadar(_ s: RadarSnapshot) { write("radar", s) }
    public static func radar() -> RadarSnapshot? { read("radar") }

    // MARK: - Relay
    public struct RelayInfo: Codable, Equatable {
        public var on: Bool?            // nil = never commanded
        public var updated: Date
        public init(on: Bool?, updated: Date) { self.on = on; self.updated = updated }
    }
    public static func saveRelay(_ r: RelayInfo) { write("relay", r) }
    public static func relay() -> RelayInfo? { read("relay") }

    // MARK: - Storage
    private static func write<T: Codable>(_ key: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value) else { return }
        defaults?.set(d, forKey: key)
    }
    private static func read<T: Codable>(_ key: String) -> T? {
        guard let d = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
