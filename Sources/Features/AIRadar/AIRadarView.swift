import SwiftUI
import WidgetKit
import UnleashedShared

@MainActor
final class AIRadarViewModel: ObservableObject {
    @Published var snapshot = AISnapshot() {
        didSet { Self.mirrorToWidgets(snapshot) }
    }

    /// Push the latest provider usage into the App Group so the AI Radar widget shows
    /// it. Keeps the last non-empty data if a refresh yields nothing.
    static func mirrorToWidgets(_ snap: AISnapshot) {
        guard !snap.providers.isEmpty else { return }
        let providers = snap.providers.map {
            SharedStore.RadarProvider(id: $0.id, name: $0.name, icon: $0.icon,
                                      shortLabel: $0.short.label, shortUsed: $0.short.used,
                                      shortReset: $0.short.reset, weeklyUsed: $0.weekly.used)
        }
        SharedStore.saveRadar(.init(providers: providers, updatedAt: snap.updatedAt))
        WidgetCenter.shared.reloadAllTimelines()
    }
    @Published var loading = false
    @Published var error: String?
    @Published var pushedToFlipper = false
    @Published var bridgeURL: String {
        didSet { UserDefaults.standard.set(bridgeURL, forKey: "aiRadarBridgeURL") }
    }

    private let storage = FlipperStorage()
    static let usageDir = "/ext/apps_data/ai_dashboard"
    static var usagePath: String { usageDir + "/usage.txt" }

    init() {
        bridgeURL = UserDefaults.standard.string(forKey: "aiRadarBridgeURL") ?? ""
    }

    func load() async {
        loading = true; error = nil; pushedToFlipper = false; defer { loading = false }
        // usageURL resolves the user's URL, or the Bonjour-discovered Mac when blank.
        if AIRadarBridgeClient.usageURL(from: bridgeURL) != nil {
            await loadFromMac(bridgeURL)
        } else {
            await loadFromFlipper()
        }
    }

    /// Pull the snapshot from the Mac bridge, show it, and forward it to the
    /// Flipper so the on-device AI Dashboard app updates too (best effort).
    private func loadFromMac(_ raw: String) async {
        guard let url = AIRadarBridgeClient.usageURL(from: raw) else { error = "Bad bridge URL"; return }
        do {
            let text = try await AIRadarBridgeClient.fetch(url)
            snapshot = AIRadarParser.parse(text)
            if snapshot.isEmpty { error = "Bridge has no provider data yet."; return }
            if FlipperBLE.shared.state == .ready {
                await AIRadarBridgeClient.persist(text, storage: storage)
                await AIRadarBridgeClient.pushViaAppBridge(text, ble: .shared)
                pushedToFlipper = true
            }
        } catch {
            self.error = "Couldn't reach the Mac bridge at \(url.host ?? raw)."
        }
    }

    /// Fallback when no Mac URL is set: read whatever usage.txt is already on the
    /// Flipper (e.g. pushed by the legacy Mac BLE bridge).
    private func loadFromFlipper() async {
        guard FlipperBLE.shared.state == .ready else {
            error = "Set the Mac bridge URL above, or connect to a Flipper."; return
        }
        do {
            let data = try await storage.read(Self.usagePath)
            snapshot = AIRadarParser.parse(String(decoding: data, as: UTF8.self))
            if snapshot.isEmpty { error = "No provider data in usage.txt yet." }
        } catch {
            self.error = "No Mac bridge URL set, and couldn't read usage.txt from the Flipper."
        }
    }
}

/// AI Radar: pulls provider usage from the Mac bridge over the local network,
/// shows it, and forwards it to the Flipper over BLE. Collection stays on the Mac
/// (it needs the codex/claude CLIs); the phone is the display + the Mac→Flipper relay.
struct AIRadarView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = AIRadarViewModel()
    @ObservedObject private var discovery = MacBridgeDiscovery.shared

    var body: some View {
        CardScroll {
            sourceCard
            if let err = vm.error, vm.snapshot.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(tint: .orange)
            }
            ForEach(vm.snapshot.providers) { p in providerCard(p) }
        }
        .navigationTitle("AI Radar")
        .navigationBarTitleDisplayMode(.inline)
        .task { discovery.start(); if vm.snapshot.isEmpty { await vm.load() } }
    }

    private var sourceCard: some View {
        SectionCard(title: "Source", systemImage: "wifi",
                    accessory: vm.snapshot.updatedAt.isEmpty ? nil :
                        AnyView(StatusPill(text: vm.snapshot.updatedAt, color: .secondary, systemImage: "clock"))) {
            TextField("Mac bridge, e.g. 192.168.1.10:8730", text: $vm.bridgeURL)
                .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            Button { Task { await vm.load() } } label: {
                Label(vm.loading ? "Loading…" : "Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(vm.loading)

            if let host = discovery.discoveredHost,
               vm.bridgeURL.trimmingCharacters(in: .whitespaces).isEmpty {
                Label("Auto-discovered \(host)", systemImage: "wifi.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Text(vm.bridgeURL.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Leave empty to auto-find the Mac bridge (Bonjour) — survives IP changes. Or type host:port to pin it."
                 : (vm.pushedToFlipper ? "Pulled from Mac · sent to Flipper." : "Pulled from Mac."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerCard(_ p: AIProvider) -> some View {
        let stale = p.source.localizedCaseInsensitiveContains("stale")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(p.icon).font(.system(.caption, design: .monospaced)).bold()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                Text(p.name).font(.headline)
                Spacer()
                StatusPill(text: p.source, color: stale ? .orange : .secondary,
                           systemImage: stale ? "exclamationmark.triangle.fill" : nil)
            }
            window(p.short)
            window(p.weekly)
            if stale {
                Label("Stale — token expired. Re-login (`claude` on the Mac).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func window(_ w: AIWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(w.label).font(.subheadline)
                Spacer()
                Text("\(w.remaining)% left").font(.caption).foregroundStyle(color(w.remaining))
            }
            ProgressView(value: Double(w.used), total: 100).tint(color(w.remaining))
            HStack {
                Text("\(w.used)% used").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !w.reset.isEmpty { Text(w.reset).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }

    private func color(_ remaining: Int) -> Color {
        remaining <= 10 ? .red : remaining <= 30 ? .orange : .green
    }
}
