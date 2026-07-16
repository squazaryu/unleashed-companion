import SwiftUI
import Combine

enum AppSort: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size"
    var id: String { rawValue }
}

@MainActor
final class InstalledAppsViewModel: ObservableObject {
    @Published var apps: [FlipperFile] = []
    @Published var loading = false
    @Published var query = ""
    @Published var sort: AppSort = .name

    private let storage = FlipperStorage()
    private var cancellable: AnyCancellable?

    init() {
        // Auto-sync: when an app is installed/updated or any file is written or
        // deleted on the Flipper, refresh the list (debounced to coalesce the
        // many writes of a multi-app pack install).
        cancellable = FlipperStorage.didChange
            .debounce(for: .seconds(1.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard FlipperBLE.shared.state == .ready else { return }
                Task { await self?.load() }
            }
    }

    func load() async {
        loading = true; defer { loading = false }
        var all: [FlipperFile] = []
        let categories = (try? await storage.list("/ext/apps")) ?? []
        for c in categories where c.isDirectory {
            let files = (try? await storage.list(c.path)) ?? []
            all += files.filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".fap") }
        }
        apps = all
    }

    var sorted: [FlipperFile] {
        let base = query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size: return base.sorted { $0.size > $1.size }
        }
    }
}

/// Flat, searchable list of everything installed under /ext/apps.
/// Note: Flipper's filesystem doesn't store per-file modification times, so we
/// can't sort by "install date" — use the Updates → history for that instead.
struct InstalledAppsView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = InstalledAppsViewModel()

    var body: some View {
        Group {
            if ble.state != .ready {
                ContentUnavailableView("Not connected", systemImage: "questionmark.app.dashed",
                    description: Text("Connect to a Flipper on the Device tab."))
            } else {
                List {
                    Section {
                        Picker("Sort", selection: $vm.sort) {
                            ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        if vm.loading { ProgressView() }
                        ForEach(vm.sorted) { f in row(f) }
                    }
                }
                .searchable(text: $vm.query, prompt: "Search installed apps")
                .refreshable { await vm.load() }
            }
        }
        .navigationTitle("Installed (\(vm.apps.count))")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ble.state) { if ble.state == .ready, vm.apps.isEmpty { await vm.load() } }
    }

    private func row(_ f: FlipperFile) -> some View {
        HStack {
            Image(systemName: "app.badge").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.name.replacingOccurrences(of: ".fap", with: ""))
                Text(category(f)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func category(_ f: FlipperFile) -> String {
        (((f.path as NSString).deletingLastPathComponent) as NSString).lastPathComponent
    }
}
