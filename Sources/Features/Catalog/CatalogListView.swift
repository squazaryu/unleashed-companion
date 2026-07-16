import SwiftUI

/// The catalog API has no real popularity signal (its `downloads` field is always 0
/// on the public endpoint), so "Featured" — the catalog's own curated picks — stands
/// in for "popular" here instead of a fake/no-op sort. Defaults to `.recent` so the
/// screen opens on fresh apps rather than the (currently one-item) featured list.
enum CatalogSort: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case all = "All"
    case featured = "Featured"
    case installed = "Installed"
    var id: String { rawValue }
}

@MainActor
final class CatalogListViewModel: ObservableObject {
    @Published var categories: [CatalogCategory] = []
    @Published var apps: [CatalogApplication] = []
    @Published var query = ""
    @Published var selectedCategory: CatalogCategory?
    @Published var sort: CatalogSort = .recent
    @Published var loading = false
    @Published var errorMessage: String?

    private let client = FlipperCatalogClient.shared
    private let storage = FlipperStorage()
    private var searchTask: Task<Void, Never>?
    /// Bumped on every reload() call; a response only commits if it's still the
    /// newest request in flight, so an out-of-order (slower, earlier) response can't
    /// clobber a faster, more recent one (e.g. debounced search racing a category tap).
    private var generation = 0

    /// First load: categories + a default browse.
    func load() async {
        if categories.isEmpty {
            categories = (try? await client.categories())?.sorted { $0.applications > $1.applications } ?? []
        }
        await reload()
    }

    func select(_ category: CatalogCategory?) {
        selectedCategory = (selectedCategory == category) ? nil : category
        searchTask?.cancel()
        Task { await reload() }
    }

    func selectSort(_ sort: CatalogSort) {
        self.sort = sort
        searchTask?.cancel()
        Task { await reload() }
    }

    /// Debounces keystrokes so we don't fire a request per character.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        generation += 1
        let thisGeneration = generation
        loading = true; errorMessage = nil

        if sort == .installed && FlipperBLE.shared.state != .ready {
            apps = []
            errorMessage = "Connect to a Flipper to see installed apps."
            loading = false
            return
        }

        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: [CatalogApplication]
            if sort == .installed {
                result = try await installedApplications()
            } else if trimmed.isEmpty && selectedCategory == nil && sort == .featured {
                // Featured is a fixed curated list (no query/category params
                // server-side); any active search or category filter takes
                // precedence over it, handled by the branch below.
                result = try await client.featured()
            } else {
                result = try await client.applications(
                    query: trimmed.isEmpty ? nil : trimmed,
                    categoryID: selectedCategory?.id,
                    sortBy: sort == .all ? .name : .updatedAt,
                    ascending: sort == .all)
            }
            guard thisGeneration == generation else { return }
            apps = result
            loading = false
        } catch {
            guard thisGeneration == generation else { return }
            apps = []
            errorMessage = "Couldn't reach the Flipper app catalog: \(error.localizedDescription)"
            loading = false
        }
    }

    /// Cross-references what's actually on the connected Flipper's SD against the
    /// catalog: list every installed .fap's filename stem, then match it against
    /// each app's `alias` (the same string the install path is built from). The
    /// catalog only has ~400 apps total, comfortably under the API's 500-item cap,
    /// so one full fetch (rather than one request per installed file) covers it.
    private func installedApplications() async throws -> [CatalogApplication] {
        guard FlipperBLE.shared.state == .ready else { return [] }
        var installedAliases: Set<String> = []
        let categoryDirs = (try? await storage.list("/ext/apps")) ?? []
        for dir in categoryDirs where dir.isDirectory {
            let files = (try? await storage.list(dir.path)) ?? []
            for f in files where !f.isDirectory && f.name.lowercased().hasSuffix(".fap") {
                installedAliases.insert((f.name as NSString).deletingPathExtension.lowercased())
            }
        }
        guard !installedAliases.isEmpty else { return [] }
        let all = try await client.applications(sortBy: .name, ascending: true, limit: 500)
        return all.filter { installedAliases.contains($0.alias.lowercased()) }
    }

    func category(for app: CatalogApplication) -> CatalogCategory? {
        categories.first { $0.id == app.categoryID }
    }
}

/// The official Flipper app catalog (catalog.flipperzero.one), browsable and
/// installable from its own screen — mirrors the "App Store" section of the
/// official Flipper mobile app.
struct CatalogListView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = CatalogListViewModel()

    var body: some View {
        List {
            Section {
                Picker("Sort", selection: Binding(
                    get: { vm.sort },
                    set: { vm.selectSort($0) }
                )) {
                    ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if !vm.categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.categories) { categoryChip($0) }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowBackground(Color.clear)

            Section {
                if vm.loading && vm.apps.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if let error = vm.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if vm.apps.isEmpty {
                    if vm.sort == .installed {
                        ContentUnavailableView("Nothing installed", systemImage: "square.grid.2x2",
                            description: Text("Apps you install from here (or elsewhere) will show up here."))
                    } else {
                        ContentUnavailableView("No apps found", systemImage: "square.grid.2x2",
                            description: Text("Try a different search or category."))
                    }
                } else {
                    ForEach(vm.apps) { app in
                        NavigationLink {
                            CatalogAppDetailView(app: app, category: vm.category(for: app))
                        } label: {
                            appRow(app)
                        }
                    }
                }
            } header: {
                if let cat = vm.selectedCategory {
                    Text(cat.name)
                } else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Results")
                } else {
                    Text(vm.sort.rawValue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $vm.query, prompt: "Search apps")
        .onChange(of: vm.query) { _, _ in vm.scheduleSearch() }
        .navigationTitle("Apps Market")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.reload() }
        .task { if vm.apps.isEmpty { await vm.load() } }
        .task(id: ble.state) { if vm.sort == .installed { await vm.reload() } }
    }

    private func categoryChip(_ category: CatalogCategory) -> some View {
        Button { vm.select(category) } label: {
            HStack(spacing: 6) {
                Circle().fill(category.tint).frame(width: 8, height: 8)
                Text(category.name).font(.caption).fontWeight(.medium)
                Text("\(category.applications)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                (vm.selectedCategory == category ? category.tint.opacity(0.22) : Color(.tertiarySystemFill)),
                in: Capsule())
            .overlay(Capsule().strokeBorder(category.tint.opacity(vm.selectedCategory == category ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func appRow(_ app: CatalogApplication) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: app.currentVersion.iconURI)) { image in
                // Catalog icons are monochrome 10x10 bitmaps (black pixels on a
                // transparent background, mirroring the Flipper's own 1-bit screen).
                // Template rendering makes them adapt to light/dark automatically;
                // .interpolation(.none) keeps the upscale crisp instead of blurring
                // a tiny pixel-art source into a smudge.
                image.resizable().interpolation(.none).renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
            } placeholder: {
                Color.clear
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.currentVersion.name).font(.subheadline).fontWeight(.medium).lineLimit(1)
                Text(app.currentVersion.shortDescription)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let cat = vm.category(for: app) {
                        Circle().fill(cat.tint).frame(width: 6, height: 6)
                        Text(cat.name).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("· v\(app.currentVersion.version)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
