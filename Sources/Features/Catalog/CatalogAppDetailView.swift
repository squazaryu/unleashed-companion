import SwiftUI
import CryptoKit

enum CatalogInstallPolicy {
    static func appStem(_ alias: String) -> String {
        (alias as NSString).deletingPathExtension.lowercased()
    }

    static func protectionReason(alias: String) -> String? {
        let stem = appStem(alias)
        guard PluginUpdater.builtInExcluded.contains(stem) else { return nil }
        return "Protected by Tumoflip. Install its firmware package version instead."
    }
}

@MainActor
final class CatalogAppDetailViewModel: ObservableObject {
    @Published var detail: CatalogApplication
    @Published var loadingDetail = false
    @Published var installedPath: String?
    @Published var busy = false
    @Published var progress: Double?
    @Published var status: String?

    private let client = FlipperCatalogClient.shared
    private let storage = FlipperStorage()
    /// Sanitized once at init — the catalog is a third-party API, so a category name or
    /// alias containing "/" or ".." must never reach a device storage path unescaped.
    let categoryName: String

    init(app: CatalogApplication, categoryName: String) {
        self.detail = app
        self.categoryName = Self.sanitize(categoryName, fallback: "Tools")
    }

    /// Keeps only characters safe for a single SD path component; folds anything else
    /// (including "/", "..", whitespace runs) so a malicious/renamed catalog entry can
    /// never escape /ext/apps/<Category>/.
    private static func sanitize(_ raw: String, fallback: String) -> String {
        let allowed = raw.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .trimmingCharacters(in: .whitespaces)
        return allowed.isEmpty ? fallback : allowed
    }

    /// Matches the official app's on-SD layout: /ext/apps/<Category>/<alias>.fap.
    var installPath: String { "/ext/apps/\(categoryName)/\(Self.sanitize(detail.alias, fallback: detail.id)).fap" }
    var protectionReason: String? {
        CatalogInstallPolicy.protectionReason(alias: detail.alias)
    }

    /// The list/search/featured endpoints omit description/changelog/links — fetch
    /// the full record once the detail screen appears.
    func loadFullDetail() async {
        loadingDetail = true; defer { loadingDetail = false }
        if let full = try? await client.detail(id: detail.id) { detail = full }
    }

    func checkInstalled() async {
        installedPath = await storage.exists(installPath) ? installPath : nil
    }

    func install() async {
        guard !busy else { return }
        if let protectionReason {
            status = protectionReason
            return
        }
        guard let build = detail.currentVersion.currentBuild else {
            status = FlipperCatalogClient.CatalogError.noBuildAvailable.errorDescription
            return
        }
        busy = true; progress = 0; defer { busy = false; progress = nil }

        status = "Downloading \(detail.currentVersion.name)…"
        let data: Data
        do {
            data = try await client.downloadBuild(versionID: detail.currentVersion.id, build)
        } catch {
            status = "Download failed: \(error.localizedDescription)"
            return
        }

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == build.fapHash else {
            status = "Download looked corrupted (hash mismatch) — try again."
            return
        }

        let info = (try? await FlipperSystem().deviceInfo()) ?? []
        let identity = Dictionary(info, uniquingKeysWith: { current, _ in current })
        let compatibility = FapCompatibility.classify(
            data: data,
            deviceApiMajor: identity["firmware_api_major"].flatMap(Int.init),
            deviceTarget: identity["hardware_target"].flatMap(Int.init))
        guard compatibility.isInstallable else {
            status = compatibility.reason ?? "Incompatible with the connected firmware."
            return
        }
        let expectedMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()

        do {
            let category = categoryName
            try await storage.makeDirectory("/ext/apps/\(category)")
            var verified = false
            for attempt in 0..<2 {
                status = attempt == 0
                    ? "Installing to \(installPath)…"
                    : "Write incomplete — retrying…"
                try await storage.write(installPath, data: data) { [weak self] sent in
                    Task { @MainActor in self?.progress = Double(sent) / Double(max(1, data.count)) }
                }
                if await storage.md5(installPath) == expectedMD5 { verified = true; break }
            }
            if verified {
                installedPath = installPath
                status = "Installed ✓ — find it under \(category) on the Flipper."
            } else {
                try? await storage.delete(installPath)
                status = "Write didn't verify — check the connection and try again."
            }
        } catch {
            status = "Install failed: \(error.localizedDescription)"
        }
    }
}

struct CatalogAppDetailView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm: CatalogAppDetailViewModel

    init(app: CatalogApplication, category: CatalogCategory?) {
        _vm = StateObject(wrappedValue: CatalogAppDetailViewModel(app: app, categoryName: category?.name ?? "Tools"))
    }

    var body: some View {
        CardScroll {
            headerCard
            if !vm.detail.currentVersion.screenshots.isEmpty { screenshotsCard }
            if let description = vm.detail.currentVersion.description, !description.isEmpty {
                descriptionCard(title: "Description", markdown: description)
            }
            if let changelog = vm.detail.currentVersion.changelog, !changelog.isEmpty {
                CollapsibleCard(title: "Changelog", systemImage: "clock.arrow.circlepath") {
                    markdownText(changelog)
                }
            }
            if let source = vm.detail.currentVersion.links?.sourceCode?.uri, let url = URL(string: source) {
                Link(destination: url) {
                    Label("View source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .navigationTitle(vm.detail.currentVersion.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { installBar }
        .task {
            await vm.loadFullDetail()
        }
        .task(id: ble.state) {
            if ble.state == .ready { await vm.checkInstalled() }
        }
    }

    private var headerCard: some View {
        SectionCard(title: vm.categoryName, systemImage: "square.grid.2x2",
                    accessory: AnyView(StatusPill(text: "v\(vm.detail.currentVersion.version)", color: .secondary))) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: vm.detail.currentVersion.iconURI)) { image in
                    // Catalog icons are monochrome 10x10 bitmaps (black pixels on a
                    // transparent background, mirroring the Flipper's own 1-bit
                    // screen). Template rendering adapts to light/dark automatically;
                    // .interpolation(.none) keeps the upscale crisp instead of blurring
                    // a tiny pixel-art source into a smudge.
                    image.resizable().interpolation(.none).renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(.primary)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.detail.currentVersion.name).font(.headline)
                    Text(vm.detail.currentVersion.shortDescription)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Text("by \(vm.detail.author)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let build = vm.detail.currentVersion.currentBuild {
                Divider().opacity(0.4)
                HStack {
                    Label("Target \(build.sdk.target) · API \(build.sdk.api)", systemImage: "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Label("\(vm.detail.downloads)", systemImage: "arrow.down.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Label("No build is published for this app yet.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var screenshotsCard: some View {
        SectionCard(title: "Screenshots", systemImage: "photo.on.rectangle") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.detail.currentVersion.screenshots, id: \.self) { uri in
                        AsyncImage(url: URL(string: uri)) { image in
                            // Same monochrome-bitmap treatment as the app icon above —
                            // screenshots are 128x64 1-bit renders of the Flipper's own
                            // screen, so the frame below matches that 2:1 aspect instead
                            // of squeezing it into a square.
                            image.resizable().interpolation(.none).renderingMode(.template)
                                .aspectRatio(contentMode: .fit)
                                .foregroundStyle(.primary)
                        } placeholder: {
                            Color.clear
                        }
                        .frame(width: 160, height: 80)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private func descriptionCard(title: String, markdown: String) -> some View {
        SectionCard(title: title, systemImage: "text.alignleft") {
            markdownText(markdown)
        }
    }

    private func markdownText(_ raw: String) -> some View {
        Text((try? AttributedString(markdown: raw)) ?? AttributedString(raw))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    @ViewBuilder private var installBar: some View {
        VStack(spacing: 6) {
            if vm.busy {
                ProgressView(value: vm.progress ?? 0)
                Text(vm.status ?? "Working…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await vm.install() }
                } label: {
                    Label(vm.installedPath != nil ? "Reinstall" : "Install",
                          systemImage: vm.installedPath != nil ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(
                    ble.state != .ready || vm.detail.currentVersion.currentBuild == nil ||
                    vm.busy || vm.protectionReason != nil)

                if let reason = vm.protectionReason {
                    Label(reason, systemImage: "lock.shield.fill")
                        .font(.caption2).foregroundStyle(.orange)
                } else if ble.state != .ready {
                    Text("Connect to a Flipper to install.").font(.caption2).foregroundStyle(.secondary)
                } else if let installedPath = vm.installedPath {
                    Label("Installed at \(installedPath)", systemImage: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green)
                } else if let status = vm.status {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.bar)
    }
}
