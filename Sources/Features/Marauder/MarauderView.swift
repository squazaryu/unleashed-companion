import SwiftUI
import Charts
import CryptoKit

@MainActor
final class MarauderViewModel: ObservableObject {
    @Published var path = "/ext/apps_data/esp32_marauder"
    @Published var allFiles: [FlipperFile] = []          // everything discovered
    @Published var filter: FileFilter = .useful
    @Published var scope: AnalyzeScope = .all            // how many of the newest files to analyze
    @Published var result: MarauderParseResult?
    @Published var loading = false
    @Published var aggregating = false
    @Published var aggregateProgress: (Int, Int)?
    @Published var status: String?

    /// Caches the aggregated overview so re-entering the tab (or relaunching) doesn't
    /// re-read all 200+ files over BLE. Re-analysis only happens when the file set or
    /// filter actually changes (different fingerprint), or on an explicit refresh.
    private var lastFingerprint: String?
    private let cacheKey = "marauder.aggregate.v2"
    private struct CachedAggregate: Codable { var fingerprint: String; var result: MarauderParseResult }

    init() { result = loadCache()?.result }   // show the last overview instantly on launch

    enum FileFilter: String, CaseIterable, Identifiable {
        case useful, captures, scans, portal, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .useful: return "Useful"
            case .captures: return "Captures"
            case .scans: return "Scans"
            case .portal: return "Portal"
            case .all: return "All"
            }
        }
    }

    /// How much to analyze. Flipper FS has no real file dates, so "newest" is by the
    /// incrementing index Marauder puts in filenames (sniffbeacon_7, scanall_10, …).
    enum AnalyzeScope: String, CaseIterable, Identifiable {
        case latest, newest5, newest20, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .latest:   return "Latest"
            case .newest5:  return "5"
            case .newest20: return "20"
            case .all:      return "All"
            }
        }
        var limit: Int? {
            switch self {
            case .latest:   return 1
            case .newest5:  return 5
            case .newest20: return 20
            case .all:      return nil
            }
        }
    }

    /// The filtered files narrowed to the current scope, newest-first by name index.
    var scopedFiles: [FlipperFile] {
        let byRecency = logFiles.sorted { recency($0.name) > recency($1.name) }
        guard let n = scope.limit else { return byRecency }
        return Array(byRecency.prefix(n))
    }

    /// Trailing `_<n>` index before the extension; higher = newer. 0 if none.
    private func recency(_ name: String) -> Int {
        let base = (name as NSString).deletingPathExtension
        guard let r = base.range(of: "_[0-9]+$", options: .regularExpression) else { return 0 }
        return Int(base[r].dropFirst()) ?? 0
    }

    /// Discovered files after the current filter — default hides info/help/update noise.
    var logFiles: [FlipperFile] {
        allFiles.filter { f in
            let k = MarauderLogKind.of(f.name)
            switch filter {
            case .useful:   return k != .other
            case .captures: return k == .capture
            case .scans:    return k == .scan
            case .portal:   return k == .portal
            case .all:      return true
            }
        }
    }

    let storage = FlipperStorage()
    // Roots Marauder / Evil Portal write to. The actual captures live in SUBFOLDERS
    // (pcaps/ logs/ dumps/), so findLogs() also recurses one level into each.
    let searchDirs = [
        "/ext/apps_data/marauder",
        "/ext/apps_data/esp32_marauder",
        "/ext/apps_data/evil_portal",
        "/ext/marauder",
    ]
    private let logExts: Set<String> = ["txt", "log", "pcap", "pcapng", "csv"]

    private func matchesLog(_ f: FlipperFile) -> Bool {
        !f.isDirectory && f.size > 0 && logExts.contains((f.name as NSString).pathExtension.lowercased())
    }

    func findLogs() async {
        loading = true; defer { loading = false }
        status = nil
        var found: [FlipperFile] = []
        for root in searchDirs {
            guard let entries = try? await storage.list(root) else { continue }
            found += entries.filter(matchesLog)
            for sub in entries where sub.isDirectory {          // pcaps/ logs/ dumps/ …
                if let subFiles = try? await storage.list(sub.path) {
                    found += subFiles.filter(matchesLog)
                }
            }
        }
        var seen = Set<String>()
        allFiles = found.filter { seen.insert($0.path).inserted }
                        .sorted { $0.size > $1.size }            // meatiest captures first
        status = allFiles.isEmpty
            ? "No Marauder logs found. Run a scan in Marauder and save it, or pick a file from the Files tab."
            : "Found \(allFiles.count) file\(allFiles.count == 1 ? "" : "s") in Marauder folders."
    }

    private func isPcap(_ f: FlipperFile) -> Bool {
        let e = (f.name as NSString).pathExtension.lowercased()
        return e == "pcap" || e == "pcapng"
    }

    /// Parse + merge every file in the current filter into one aggregated result.
    /// Text logs are read first (tiny → instant overview), then captures stream in,
    /// and the infographic updates live after each file. Runs automatically after
    /// discovery; re-run from the button after changing the filter.
    func analyzeAll() async {
        let files = scopedFiles.sorted {
            ((isPcap($0) ? 1 : 0), $0.size) < ((isPcap($1) ? 1 : 0), $1.size)
        }
        guard !files.isEmpty else { return }
        aggregating = true
        defer { aggregating = false; aggregateProgress = nil }
        var results: [MarauderParseResult] = []
        for (i, f) in files.enumerated() {
            if Task.isCancelled { return }
            aggregateProgress = (i, files.count)
            guard let data = try? await storage.read(f.path) else { continue }
            switch MarauderPcap.detectFormat(data) {
            case .classicPcap:
                if let r = MarauderPcap.parse(data) { results.append(r) }
            case .pcapng:
                continue
            case .text:
                var r = MarauderLogParser.parse(String(decoding: data, as: UTF8.self))
                r.aps = r.aps.map { var a = $0; a.vendor = MarauderPcap.vendor(for: a.bssid); return a }
                results.append(r)
            }
            result = MarauderParseResult.aggregate(results)   // live, growing overview
        }
        let agg = result ?? MarauderParseResult.aggregate(results)
        let fp = fingerprint()
        lastFingerprint = fp
        saveCache(fp)
        status = "Aggregated \(files.count) file\(files.count == 1 ? "" : "s") → \(agg.aps.count) networks · \(agg.stations.count) clients · \(agg.credentials.count) creds"
    }

    /// On appear: only list the files and show the cached overview. Building/rebuilding
    /// the analytics is left entirely to the Analyze / ↻ buttons.
    func refreshOnAppear() async {
        await findLogs()
        if result == nil, let cached = loadCache() {
            result = cached.result
            lastFingerprint = cached.fingerprint
        }
    }

    /// True when the shown overview doesn't match the current filter/scope/files — i.e.
    /// tapping Analyze would change it. Drives the "tap Analyze to update" hint.
    var needsRebuild: Bool { result != nil && lastFingerprint != fingerprint() }

    /// Stable signature of the current filter + scope + scoped file set (path + size).
    private func fingerprint() -> String {
        let sig = "\(filter.rawValue)|\(scope.rawValue)|" + scopedFiles.sorted { $0.path < $1.path }
            .map { "\($0.path):\($0.size)" }.joined(separator: ";")
        return SHA256.hash(data: Data(sig.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func saveCache(_ fp: String) {
        guard let result,
              let data = try? JSONEncoder().encode(CachedAggregate(fingerprint: fp, result: result))
        else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func loadCache() -> CachedAggregate? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedAggregate.self, from: data)
    }

    func analyze(_ file: FlipperFile) async {
        loading = true; defer { loading = false }
        status = "Reading \(file.name)…"
        do {
            let data = try await storage.read(file.path)
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            switch MarauderPcap.detectFormat(data) {
            case .classicPcap(let dlt):
                if let r = MarauderPcap.parse(data) {
                    result = r
                    status = "\(file.name) · pcap DLT \(dlt) · \(size) → \(r.aps.count) networks, \(r.stations.count) clients"
                } else {
                    result = MarauderParseResult()
                    status = "\(file.name) · \(size): pcap link-type \(dlt) isn't supported (need 802.11=105 or radiotap=127)."
                }
            case .pcapng:
                result = MarauderParseResult()
                status = "\(file.name) · \(size): this is a pcapng capture — not parsed yet. Re-save it as a classic .pcap."
            case .text:
                var r = MarauderLogParser.parse(String(decoding: data, as: UTF8.self))
                r.aps = r.aps.map { var a = $0; a.vendor = MarauderPcap.vendor(for: a.bssid); return a }
                result = r
                status = "\(file.name) · text · \(size) · \(r.rawLines) lines → \(r.aps.count) APs, \(r.credentials.count) creds"
            }
        } catch { status = error.localizedDescription }
    }
}

struct MarauderView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = MarauderViewModel()
    @State private var showPicker = false
    @State private var filesExpanded = false

    var body: some View {
        // Stack-agnostic: rendered inside Home's NavigationStack (WiFi is no longer a tab).
        Group {
            if ble.state != .ready {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash",
                    description: Text("Connect to a Flipper from Home."))
            } else {
                content
            }
        }
        .navigationTitle("Marauder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { MarauderLiveView() } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                        .disabled(ble.state != .ready)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "folder.badge.plus") }
                        .disabled(ble.state != .ready)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await vm.findLogs(); await vm.analyzeAll() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(ble.state != .ready)
                }
            }
            .sheet(isPresented: $showPicker) {
                // Start where Marauder saves (per its save_*_here.setting markers); the
                // picker can navigate anywhere on the SD from there.
                FlipperFilePickerView(storage: vm.storage, start: "/ext/apps_data/marauder") { f in
                    Task { await vm.analyze(f) }
                }
            }
            .task(id: ble.state) { if ble.state == .ready { await vm.refreshOnAppear() } }
    }

    private var content: some View {
        CardScroll {
            mapperCard
            controlCard                       // filter + analyze (compact, top)
            if let r = vm.result {            // statistics right under the controls
                if r.aps.isEmpty && r.stations.isEmpty && r.credentials.isEmpty {
                    emptyResultCard
                } else {
                    infographicCard(r)
                    if !r.credentials.isEmpty { credsCard(r) }
                    if !r.aps.isEmpty { marauderNetworksCard(r) }
                    if !r.unassociatedStations.isEmpty { marauderOtherClientsCard(r) }
                }
            }
            filesCard                         // the long file list, collapsed at the bottom
        }
    }

    private var mapperCard: some View {
        SectionCard(title: "TumoSurvey Maps", systemImage: "map") {
            NavigationLink {
                WiFiMapperLiveMapView()
            } label: {
                mapperRow(icon: "location.viewfinder", tint: .green,
                          title: "Live map (iPhone GPS)",
                          subtitle: "Triangulate APs live from your phone's location")
            }
            .buttonStyle(.plain)
            Divider().opacity(0.4)
            NavigationLink {
                WiFiMapperMapView()
            } label: {
                mapperRow(icon: "map.fill", tint: Theme.accent,
                          title: "Open exported WiFi map",
                          subtitle: "/ext/apps_data/wifi_mapper/exports")
            }
            .buttonStyle(.plain)
        }
    }

    private func mapperRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private var emptyResultCard: some View {
        SectionCard(title: "Nothing parsed", systemImage: "questionmark.text.page") {
            Text("That file had no networks, clients, or credentials. Likely:")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            bullet("It's an info / help / status log, not a scan or sniff — switch the filter to Captures or Scans, or use “Analyze all”.")
            bullet("An empty capture (a sniff that recorded no frames).")
            bullet("A pcapng file — not parsed yet (re-save as a classic .pcap).")
            if let s = vm.status {
                Text(s).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infographicCard(_ r: MarauderParseResult) -> some View {
        SectionCard(title: "Overview", systemImage: "chart.bar.xaxis") {
            HStack {
                statTile("\(r.aps.count)", "networks")
                statTile("\(r.stations.count)", "clients")
                statTile("\(r.credentials.count)", "creds")
                if r.handshakes > 0 { statTile("\(r.handshakes)", "EAPOL") }
            }
            let channels = channelCounts(r)
            if !channels.isEmpty {
                Divider().opacity(0.4)
                Text("Networks per channel").font(.caption2).foregroundStyle(.secondary)
                Chart(channels, id: \.channel) { c in
                    BarMark(x: .value("Channel", String(c.channel)), y: .value("Networks", c.count))
                        .foregroundStyle(Theme.accent)
                }
                .frame(height: 130)
            }
            let vendors = topVendors(r)
            if !vendors.isEmpty {
                Divider().opacity(0.4)
                Text("Top vendors").font(.caption2).foregroundStyle(.secondary)
                Chart(vendors, id: \.vendor) { v in
                    BarMark(x: .value("Devices", v.count), y: .value("Vendor", v.vendor))
                        .foregroundStyle(Theme.accent)
                }
                .frame(height: CGFloat(vendors.count * 26 + 16))
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3).fontWeight(.bold).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func channelCounts(_ r: MarauderParseResult) -> [(channel: Int, count: Int)] {
        Dictionary(grouping: r.aps.compactMap(\.channel), by: { $0 })
            .map { (channel: $0.key, count: $0.value.count) }
            .sorted { $0.channel < $1.channel }
    }

    private func topVendors(_ r: MarauderParseResult) -> [(vendor: String, count: Int)] {
        let all = (r.aps.compactMap(\.vendor) + r.stations.compactMap(\.vendor))
            .filter { $0 != "Unknown" && !$0.isEmpty }
        return Dictionary(grouping: all, by: { $0 })
            .map { (vendor: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(8).map { $0 }
    }

    private func parentFolder(_ path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(t).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Compact top card: the filter segments + one Analyze button. No file list, so the
    /// statistics below are reachable without scrolling past hundreds of files.
    private var controlCard: some View {
        SectionCard(title: "Analyze", systemImage: "chart.bar.xaxis") {
            if !vm.allFiles.isEmpty {
                Picker("Filter", selection: $vm.filter) {
                    ForEach(MarauderViewModel.FileFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text("Scope").font(.caption).foregroundStyle(.secondary)
                    Picker("Scope", selection: $vm.scope) {
                        ForEach(MarauderViewModel.AnalyzeScope.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Button { Task { await vm.analyzeAll() } } label: {
                    if vm.aggregating {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(vm.aggregateProgress.map { "Analyzing \($0.0 + 1)/\($0.1)…" } ?? "Analyzing…")
                        }.frame(maxWidth: .infinity)
                    } else {
                        Label("\(vm.result == nil ? "Analyze" : "Rebuild") \(vm.scopedFiles.count) file\(vm.scopedFiles.count == 1 ? "" : "s")",
                              systemImage: "chart.bar.doc.horizontal")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(vm.aggregating || vm.scopedFiles.isEmpty)

                if vm.needsRebuild {
                    Label("Filter or scope changed — tap to rebuild.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2).foregroundStyle(.orange)
                } else if let s = vm.status {
                    Text(s).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if vm.loading {
                HStack { ProgressView(); Text("Scanning the SD…").foregroundStyle(.secondary) }
            } else {
                Text("No Marauder logs on the SD yet. Run a scan in Marauder and save it, then tap ↻.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The raw file list, collapsed by default and parked at the bottom — only needed to
    /// inspect one specific capture, not for the aggregated statistics.
    @ViewBuilder private var filesCard: some View {
        if !vm.allFiles.isEmpty {
            SectionCard(title: "Files", systemImage: "doc.text.magnifyingglass",
                        accessory: AnyView(StatusPill(text: "\(vm.logFiles.count)", color: .secondary))) {
                DisclosureGroup(isExpanded: $filesExpanded) {
                    if vm.logFiles.isEmpty {
                        Text("Nothing in this filter — try another tab.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 8) { ForEach(vm.logFiles) { fileRow($0) } }.padding(.top, 6)
                    }
                } label: {
                    Text(filesExpanded
                         ? "Hide files"
                         : "Show \(vm.logFiles.count) file\(vm.logFiles.count == 1 ? "" : "s") — tap one to inspect")
                        .font(.subheadline)
                }
                .tint(.secondary)
            }
        }
    }

    private func fileRow(_ f: FlipperFile) -> some View {
        Button { Task { await vm.analyze(f) } } label: {
            HStack {
                Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    Text(parentFolder(f.path)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func credsCard(_ r: MarauderParseResult) -> some View {
        SectionCard(title: "Captured credentials", systemImage: "key.fill",
                    accessory: AnyView(StatusPill(text: "\(r.credentials.count)", color: .orange))) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(r.credentials) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.username).font(.headline)
                        Text(c.password).font(.system(.body, design: .monospaced)).foregroundStyle(.orange)
                        Text(c.source).font(.caption2).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
            }
        }
    }

}

/// Browse the Flipper SD and pick any file to analyze. Folders are navigable;
/// tapping a file selects it. Starts at `start`, falls back upward if missing.
struct FlipperFilePickerView: View {
    let storage: FlipperStorage
    let start: String
    let onPick: (FlipperFile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var entries: [FlipperFile] = []
    @State private var loading = false

    init(storage: FlipperStorage, start: String, onPick: @escaping (FlipperFile) -> Void) {
        self.storage = storage; self.start = start; self.onPick = onPick
        _path = State(initialValue: start)
    }

    private var folders: [FlipperFile] { entries.filter { $0.isDirectory } }
    private var files: [FlipperFile] { entries.filter { !$0.isDirectory } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(path).font(.system(.footnote, design: .monospaced))
                            .lineLimit(1).truncationMode(.head)
                        Spacer()
                        if path != "/" {
                            Button { Task { await up() } } label: { Image(systemName: "arrow.up.left") }
                        }
                    }
                }
                if loading { Section { ProgressView() } }
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { d in
                            Button { Task { await load(d.path) } } label: {
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(.orange)
                                    Text(d.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section(files.isEmpty ? "Files" : "Files — tap to analyze") {
                    if files.isEmpty && !loading {
                        Text("No files here").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(files) { f in
                        Button { onPick(f); dismiss() } label: {
                            HStack {
                                Image(systemName: fileIcon(f.name)).foregroundStyle(Theme.accent)
                                Text(f.name).lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pick a log file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .task {
                // Try the requested folder, falling back upward if it doesn't exist.
                for p in [start, "/ext/apps_data", "/ext"] {
                    if let e = try? await storage.list(p) { path = p; entries = e; return }
                }
            }
        }
    }

    private func load(_ p: String) async {
        loading = true; defer { loading = false }
        path = p
        entries = (try? await storage.list(p)) ?? []
    }

    private func up() async {
        let parent = (path as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pcap": return "doc.viewfinder"
        case "log", "txt", "csv": return "doc.text"
        default: return "doc"
        }
    }
}
