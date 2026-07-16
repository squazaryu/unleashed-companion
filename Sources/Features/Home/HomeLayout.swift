import SwiftUI

/// A destination that can live as a tile on the Home screen (and double as a deep-link route).
enum HomeTileID: String, Codable, CaseIterable, Identifiable, Hashable {
    case info, apps, files, airadar, wifi, spectrum, relay, tumonet, esp32, updates, backup, remotes, media
    var id: String { rawValue }

    var title: String {
        switch self {
        case .info:    return "Info"
        case .apps:    return "Apps"
        case .files:   return "Files"
        case .airadar: return "AI Radar"
        case .wifi:    return "TumoSurvey"
        case .spectrum: return "TumoSpectrum"
        case .relay:   return "Relay"
        case .tumonet: return "TumoNet"
        case .esp32:   return "ESP32"
        case .updates: return "Updates"
        case .backup:  return "Backup"
        case .remotes: return "Remotes"
        case .media:   return "Media"
        }
    }

    var systemImage: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .apps:    return "square.grid.2x2.fill"
        case .files:   return "folder.fill"
        case .airadar: return "chart.bar.xaxis"
        case .wifi:    return "wifi"
        case .spectrum: return "waveform.path.ecg"
        case .relay:   return "antenna.radiowaves.left.and.right"
        case .tumonet: return "point.3.connected.trianglepath.dotted"
        case .esp32:   return "cpu"
        case .updates: return "arrow.triangle.2.circlepath"
        case .backup:  return "externaldrive.badge.timemachine"
        case .remotes: return "dot.radiowaves.right"
        case .media:   return "music.note"
        }
    }

    var tint: Color {
        switch self {
        case .info:    return .blue
        case .apps:    return .indigo
        case .files:   return .cyan
        case .airadar: return .green
        case .wifi:    return .mint
        case .spectrum: return .orange
        case .relay:   return .red
        case .tumonet: return .orange
        case .esp32:   return .pink
        case .updates: return .teal
        case .backup:  return .purple
        case .remotes: return .orange
        case .media:   return .pink
        }
    }

    var spec: DashTileSpec { DashTileSpec(title: title, systemImage: systemImage, tint: tint) }
}

/// The three collapsible sections on Home.
enum HomeGroupID: String, Codable, CaseIterable, Identifiable {
    case info, tools, revision
    var id: String { rawValue }

    var name: String {
        switch self {
        case .info:     return "Info"
        case .tools:    return "Tools"
        case .revision: return "Revision"
        }
    }

    var systemImage: String {
        switch self {
        case .info:     return "info.circle"
        case .tools:    return "wrench.and.screwdriver"
        case .revision: return "clock.arrow.circlepath"
        }
    }
}

private struct HomeLayoutData: Codable {
    var info: [String]
    var tools: [String]
    var revision: [String]
    var hidden: [String]
    var collapsed: [String]

    static var `default`: HomeLayoutData {
        .init(info: ["info", "apps", "files"],
              tools: ["airadar", "wifi", "spectrum", "relay", "tumonet", "esp32"],
              revision: ["updates", "backup", "remotes"],
              hidden: [],
              collapsed: [])
    }
}

/// Persisted, user-editable Home layout: which tiles sit in which group, their order,
/// what's hidden, and which groups are collapsed. Edited from `CustomizeHomeView`,
/// rendered by `DevicesView`.
final class HomeLayoutStore: ObservableObject {
    static let shared = HomeLayoutStore()
    private let key = "home.layout.v1"

    @Published private(set) var order: [HomeGroupID: [HomeTileID]] = [:]
    @Published private(set) var hidden: [HomeTileID] = []
    @Published private(set) var collapsed: Set<HomeGroupID> = []

    private init() { load() }

    // MARK: - Reads

    func tiles(_ group: HomeGroupID) -> [HomeTileID] { order[group] ?? [] }
    func isExpanded(_ group: HomeGroupID) -> Bool { !collapsed.contains(group) }

    // MARK: - Mutations (each persists)

    func toggle(_ group: HomeGroupID) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        save()
    }

    func reorder(_ group: HomeGroupID, from source: IndexSet, to dest: Int) {
        var arr = order[group] ?? []
        arr.move(fromOffsets: source, toOffset: dest)
        order[group] = arr
        save()
    }

    func move(_ tile: HomeTileID, to group: HomeGroupID) {
        removeEverywhere(tile)
        order[group, default: []].append(tile)
        save()
    }

    func hide(_ tile: HomeTileID) {
        removeEverywhere(tile)
        hidden.append(tile)
        save()
    }

    func unhide(_ tile: HomeTileID, to group: HomeGroupID) {
        removeEverywhere(tile)
        order[group, default: []].append(tile)
        save()
    }

    func reset() { apply(.default); save() }

    private func removeEverywhere(_ tile: HomeTileID) {
        for g in HomeGroupID.allCases { order[g]?.removeAll { $0 == tile } }
        hidden.removeAll { $0 == tile }
    }

    // MARK: - Persistence

    private func load() {
        let raw = UserDefaults.standard.data(forKey: key) ?? Data()
        let data = (try? JSONDecoder().decode(HomeLayoutData.self, from: raw)) ?? .default
        apply(data)
    }

    private func apply(_ data: HomeLayoutData) {
        func ids(_ a: [String]) -> [HomeTileID] { a.compactMap { HomeTileID(rawValue: $0) } }
        var o: [HomeGroupID: [HomeTileID]] = [
            .info: ids(data.info), .tools: ids(data.tools), .revision: ids(data.revision)
        ]
        var hid = ids(data.hidden)
        // De-dupe across groups + hidden; ensure every known tile appears exactly once so
        // a tile added in a future version still shows up (defaults into Tools).
        var seen = Set<HomeTileID>()
        for g in HomeGroupID.allCases { o[g] = (o[g] ?? []).filter { seen.insert($0).inserted } }
        hid = hid.filter { seen.insert($0).inserted }
        for t in HomeTileID.allCases where !seen.contains(t) {
            o[.tools, default: []].append(t); seen.insert(t)
        }
        order = o
        hidden = hid
        collapsed = Set(data.collapsed.compactMap { HomeGroupID(rawValue: $0) })
    }

    private func save() {
        func raw(_ a: [HomeTileID]) -> [String] { a.map(\.rawValue) }
        let data = HomeLayoutData(
            info: raw(order[.info] ?? []),
            tools: raw(order[.tools] ?? []),
            revision: raw(order[.revision] ?? []),
            hidden: raw(hidden),
            collapsed: collapsed.map(\.rawValue))
        if let d = try? JSONEncoder().encode(data) { UserDefaults.standard.set(d, forKey: key) }
    }
}
