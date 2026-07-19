import SwiftUI

/// A titled card whose body collapses behind a tappable header (with an optional
/// summary accessory + chevron). Used for the "Needs attention" card, which should
/// only occupy screen space when there's genuinely something to act on.
struct CollapsibleCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var accessory: AnyView? = nil
    var contentSpacing: CGFloat
    var cardPadding: CGFloat
    @State private var expanded: Bool
    @ViewBuilder var content: Content

    init(title: String, systemImage: String? = nil, accessory: AnyView? = nil,
         contentSpacing: CGFloat = 12, cardPadding: CGFloat = 16,
         startExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory
        self.contentSpacing = contentSpacing
        self.cardPadding = cardPadding
        self._expanded = State(initialValue: startExpanded)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if let systemImage {
                        Image(systemName: systemImage).font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text(title.uppercased())
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary).tracking(0.5)
                    Spacer()
                    if let accessory { accessory }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: cardPadding)
    }
}

/// Unified "App Updates" hub. Owns BOTH update sources — tumoflip firmware packages and
/// all-the-plugins community apps — as a single screen with one combined verdict header
/// and a single "Sources" card listing the two as comparable peer rows. Each row collapses
/// its entire backend (a 4-group dashboard, or a 50-300 row file diff) into one verdict
/// badge; all browsing/selection detail lives one tap away on that source's own screen, so
/// this dashboard's height never grows regardless of how much is pending underneath.
struct UpdatesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @EnvironmentObject var updates: UpdatesCoordinator
    @State private var showHelp = false

    private var updater: PluginUpdater { updates.plugins }
    private var packages: TumoflipUpdater { updates.packages }
    private var firmware: FirmwareLibrary { updates.firmware }

    var body: some View {
        CardScroll {
            headerView
            sourcesCard
            attentionCard
            moreCard
        }
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Updates help")
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onAppear { updates.loadIfNeeded(recoverPackages: hasFileChannel) }
        .onChange(of: ble.state) { _, state in updates.revalidateAfterReady(state) }
        .sheet(isPresented: $showHelp) { UpdatesHelpView() }
    }

    private var hasFileChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    // MARK: - Header (single combined verdict, no card chrome)

    private var pluginChecking: Bool {
        switch updater.phase {
        case .fetching, .downloading, .scanning: return true
        default: return false
        }
    }

    private var firmwareChecking: Bool {
        switch packages.phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    private var hasAttentionItems: Bool {
        if updater.phase == .needsBaseline { return true }
        if updater.pendingProtectedReview.count > 0 { return true }
        if let vr = updater.verifyResult, !vr.ok { return true }
        if let warning = packages.firmwareRoute.warning, warning != .identityUnavailable { return true }
        if case .failed = packages.phase { return true }
        if case .failed = firmware.phase { return true }
        return false
    }

    /// True when the firmware source needs SOME action — either an update OR a fresh
    /// install. Mirrors `firmwareBadge`'s own up-to-date/not-installed split so the header
    /// sentence can never contradict the Sources row (e.g. row says "Not installed" while
    /// the header says "Everything is up to date").
    private var firmwareNeedsAction: Bool {
        guard packages.manifest != nil else { return false }
        switch packages.overallStatus {
        case .updateAvailable, .notInstalled: return true
        case .upToDate, .empty: return false
        }
    }

    private var headerVerdict: (text: String, color: Color, showSpinner: Bool) {
        if pluginChecking || firmwareChecking { return ("Checking for updates…", .secondary, true) }
        if hasAttentionItems { return ("Needs your attention", .orange, false) }
        let pluginNeedsAction = !updater.updates.isEmpty
        let firmwareAction = firmwareNeedsAction
        if pluginNeedsAction && firmwareAction { return ("FW Package and app updates available", .orange, false) }
        if firmwareAction { return ("FW Package updates available", .orange, false) }
        if pluginNeedsAction { return ("Community app updates available", .orange, false) }
        if updater.tag.isEmpty && packages.manifest == nil && firmware.releases.isEmpty {
            return ("Choose a source", .secondary, false)
        }
        return ("Everything is up to date", .green, false)
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            if headerVerdict.showSpinner { ProgressView().scaleEffect(0.8) }
            Text(headerVerdict.text)
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(headerVerdict.color)
                .lineLimit(1)
            Spacer()
            StatusPill(
                text: transfer.activeChannel.label,
                color: transfer.activeChannel == .usb ? .blue : .secondary,
                systemImage: transfer.activeChannel.systemImage
            )
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Sources

    private var pluginBadge: SourceBadge {
        if updater.phase == .needsBaseline { return .notChecked }
        if updater.tag.isEmpty { return .notChecked }
        return updater.updates.isEmpty ? .upToDate : .updatesAvailable(updater.updates.count)
    }

    private var packagesBadge: SourceBadge {
        guard packages.manifest != nil else { return .notChecked }
        switch packages.overallStatus {
        case .upToDate: return .upToDate
        case .notInstalled: return .notInstalled
        case .empty: return .notChecked
        case .updateAvailable:
            let n = packages.groupStatus.values.filter { $0 == .updateAvailable }.count
            return .updatesAvailable(n, of: TumoflipManifest.knownGroups.count)
        }
    }

    private var firmwareLibraryBadge: SourceBadge {
        if firmware.busy { return .checking }
        guard !firmware.releases.isEmpty else { return .notChecked }
        guard let installed = firmware.installedVersion else { return .notInstalled }
        if firmware.visibleReleases.first?.version == installed { return .upToDate }
        return .updatesAvailable(firmware.visibleReleases.count)
    }

    private var sourcesCard: some View {
        SectionCard(title: "Sources", systemImage: "shippingbox") {
            VStack(spacing: 14) {
                NavigationLink { FirmwareLibraryView(library: firmware) } label: {
                    SourceRow(icon: "memorychip.fill", tint: .orange, title: "Firmware",
                              subtitle: "Main and Dev releases",
                              badge: firmwareLibraryBadge, busy: firmware.busy)
                }
                Divider()
                NavigationLink { TumoflipUpdaterView(updater: packages) } label: {
                    SourceRow(icon: "shippingbox.fill", tint: .blue, title: "FW Packages",
                              subtitle: packages.firmwareRoute.channel.packageLabel,
                              badge: packagesBadge, busy: firmwareChecking)
                }
                Divider()
                NavigationLink { PluginUpdatesDetailView(updater: updater) } label: {
                    SourceRow(icon: "puzzlepiece.extension.fill", tint: .indigo, title: "Community apps",
                              subtitle: "all-the-plugins", badge: pluginBadge, busy: pluginChecking)
                }
            }
        }
    }

    // MARK: - Needs attention (conditional — only when something blocks normal flow)

    @ViewBuilder private var attentionCard: some View {
        if hasAttentionItems {
            CollapsibleCard(title: "Needs attention", systemImage: "exclamationmark.shield.fill", startExpanded: true) {
                VStack(spacing: 10) {
                    if updater.phase == .needsBaseline {
                        NavigationLink { PluginUpdatesDetailView(updater: updater) } label: {
                            AttentionRow(systemImage: "magnifyingglass", text: "Community apps — first sync needed", tint: .blue)
                        }
                    }
                    if updater.pendingProtectedReview.count > 0 {
                        let n = updater.pendingProtectedReview.count
                        NavigationLink { ProtectedAppsView(updater: updater) } label: {
                            AttentionRow(systemImage: "lock.trianglebadge.exclamationmark",
                                         text: "\(n) protected app\(n == 1 ? "" : "s") to review", tint: .orange)
                        }
                    }
                    if let vr = updater.verifyResult, !vr.ok {
                        NavigationLink { PluginUpdatesDetailView(updater: updater) } label: {
                            AttentionRow(systemImage: "exclamationmark.triangle.fill",
                                         text: "Last verify found \(vr.failed.count) issue\(vr.failed.count == 1 ? "" : "s")", tint: .red)
                        }
                    }
                    if case .failed(let msg) = packages.phase {
                        NavigationLink { TumoflipUpdaterView(updater: packages) } label: {
                            AttentionRow(systemImage: "exclamationmark.triangle.fill", text: "FW Packages: \(msg)", tint: .red)
                        }
                    }
                    if let warning = packages.firmwareRoute.warning, warning != .identityUnavailable {
                        NavigationLink { TumoflipUpdaterView(updater: packages) } label: {
                            AttentionRow(systemImage: "point.3.connected.trianglepath.dotted",
                                         text: "Firmware channel: \(warning.message)", tint: .orange)
                        }
                    }
                    if case .failed(let message) = firmware.phase {
                        NavigationLink { FirmwareLibraryView(library: firmware) } label: {
                            AttentionRow(systemImage: "exclamationmark.triangle.fill",
                                         text: "Firmware library: \(message)", tint: .red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - More (utility, trimmed — Firmware packages is now a Sources row, not a link here)

    private var moreCard: some View {
        SectionCard(title: "More", systemImage: "ellipsis.circle") {
            NavigationLink { ProtectedAppsView(updater: updater) } label: {
                navRow(icon: "lock.shield.fill", color: .indigo, title: "Protected apps",
                       subtitle: "\(updater.builtInProtectedNames.count) built-in · \(updater.customProtectedNames.count) custom · \(updater.pendingProtectedReview.count) to review")
            }
            Divider()
            NavigationLink { HistoryView(updater: updater) } label: {
                navRow(icon: "clock.arrow.circlepath", color: .secondary, title: "Install history",
                       subtitle: "Past installs & updates")
            }
        }
    }

    /// Row label for a card NavigationLink — cards don't draw the List disclosure
    /// chevron, so we add icon + title + subtitle + chevron ourselves.
    private func navRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Bottom action bar (combined — one bar, honest about two distinct transactions)

    private var firmwareSelectedCount: Int { packages.selectedFileCount }

    @ViewBuilder private var actionBar: some View {
        let pluginN = updater.selectedCount
        // No install archive published yet for this release → nothing to install, even
        // though the manifest (and a default group selection) already loaded.
        let firmwareN = packages.hasPackageZip ? firmwareSelectedCount : 0
        if (pluginN > 0 || firmwareN > 0), !pluginChecking, !packages.busy {
            VStack(spacing: firmwareN > 0 && pluginN > 0 ? 6 : 0) {
                if firmwareN > 0 {
                    let firmwareBlocked = packages.validating ||
                        (packages.selectedRequiresCompatibilityIdentity && !packages.hasFreshCompatibilityIdentity)
                    if packages.selectedRequiresCompatibilityIdentity && !packages.hasFreshCompatibilityIdentity {
                        Label("Connect Flipper over BLE to validate apps before installing via \(transfer.activeChannel.label).",
                              systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    installButton(title: "Install \(firmwareN) FW Package file\(firmwareN == 1 ? "" : "s")",
                                  blocked: firmwareBlocked) {
                        Task { await packages.install() }
                    }
                }
                if pluginN > 0 {
                    installButton(title: "Install \(pluginN) plugin file\(pluginN == 1 ? "" : "s")",
                                  blocked: ble.state != .ready || updater.validating) {
                        Task { await updater.install() }
                    }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private func installButton(title: String, blocked: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(!hasFileChannel || blocked)
    }
}

/// Dedicated screen for managing protected (never-updated) apps. Kept off the
/// main Updates list so the "unprotect" control can't be tapped by accident —
/// removal is a deliberate left-swipe, not a one-tap minus.
struct ProtectedAppsView: View {
    @ObservedObject var updater: PluginUpdater
    @State private var newExclusion = ""

    var body: some View {
        List {
            if !updater.pendingProtectedReview.isEmpty {
                Section {
                    ForEach(updater.pendingProtectedReview) { item in
                        ProtectedReviewRow(
                            item: item,
                            compatibility: updater.classification(item.remotePath))
                    }
                } header: {
                    Text("Needs review")
                } footer: {
                    Text("Protected apps that all-the-plugins also ships. Review upstream changes before deciding whether to replace your tumoflip/custom build (run “Check for updates” to refresh this).")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                ForEach(updater.builtInProtectedNames, id: \.self) { name in
                    let lifted = updater.isBuiltInUnprotected(name)
                    HStack {
                        Image(systemName: lifted ? "lock.open" : "lock.shield.fill")
                            .foregroundStyle(lifted ? .orange : .indigo).font(.caption)
                        Text(name).font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(lifted ? .secondary : .primary)
                        Spacer()
                        Text(lifted ? "unprotected" : "tumoflip")
                            .font(.caption2)
                            .foregroundStyle(lifted ? .orange : .secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        if lifted {
                            Button { updater.addExclusion(name) } label: {
                                Label("Re-protect", systemImage: "lock.shield")
                            }.tint(.indigo)
                        } else {
                            Button(role: .destructive) { updater.removeExclusion(name) } label: {
                                Label("Unprotect", systemImage: "lock.open")
                            }
                        }
                    }
                }
            } header: {
                Text("Tumoflip protected")
            } footer: {
                Text("Built-in protections for tumoflip / locally-modified apps — normally skipped by all-the-plugins. Swipe a row to Unprotect it if you want all-the-plugins to manage that app; Re-protect anytime.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if updater.customProtectedNames.isEmpty {
                    Text("No custom protected apps yet.")
                        .foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(updater.customProtectedNames, id: \.self) { name in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.indigo).font(.caption)
                        Text(name).font(.system(.footnote, design: .monospaced))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { updater.removeExclusion(name) } label: {
                            Label("Unprotect", systemImage: "lock.open")
                        }
                    }
                }
            } header: {
                Text("Custom protected")
            } footer: {
                Text("Custom names are also skipped during automatic install. The Community apps screen still shows upstream differences for review. Swipe a custom row left to unprotect it.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Add protection") {
                HStack {
                    TextField("app name (e.g. quac)", text: $newExclusion)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onSubmit { addCurrent() }
                    Button { addCurrent() } label: {
                        Image(systemName: "plus.circle.fill")
                    }.disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("Protected apps")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addCurrent() {
        let name = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        updater.addExclusion(name)
        newExclusion = ""
    }
}

struct HistoryView: View {
    @ObservedObject var updater: PluginUpdater

    var body: some View {
        Group {
            if updater.history.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock",
                    description: Text("Installs and updates will appear here."))
            } else {
                List {
                    ForEach(releaseTags, id: \.self) { tag in
                        Section(tag) {
                            ForEach(updater.history.filter { $0.tag == tag }) { rec in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rec.name).font(.subheadline)
                                        Text("\(rec.pack) · \(rec.date.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(rec.wasNew ? "NEW" : "UPD")
                                        .font(.caption2).bold()
                                        .foregroundStyle(rec.wasNew ? .green : .orange)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Install history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !updater.history.isEmpty {
                Button(role: .destructive) { updater.clearHistory() } label: { Text("Clear") }
            }
        }
    }

    private var releaseTags: [String] {
        var seen: [String] = []
        for r in updater.history where !seen.contains(r.tag) { seen.append(r.tag) }
        return seen
    }
}

/// A protected app that all-the-plugins also ships, with its on-device-vs-upstream
/// comparison status. Used by `ProtectedAppsView`'s "Needs review" section.
struct ProtectedReviewRow: View {
    let item: ProtectedPluginReview
    let compatibility: FapCompatibilityState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.deviceKnown ? "lock.fill" : "questionmark.circle.fill")
                .foregroundStyle(item.deviceKnown ? .orange : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline)
                Text(item.isRouted ? "\(item.category) -> \(item.targetCategory) (tumoflip route)" : "\(item.category) · \(item.pack)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let reason = compatibility.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let metadata = compatibility.metadata {
                    Text("API \(metadata.apiVersionString) · target \(metadata.hardwareTarget)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(item.deviceKnown ? (item.deviceMD5 == nil ? "MISSING" : "DIFF") : "CHECK")
                .font(.caption2)
                .bold()
                .foregroundStyle(item.deviceKnown ? .orange : .secondary)
        }
        .padding(.vertical, 3)
    }
}
