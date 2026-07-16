import SwiftUI

/// Detail screen for the "Community apps" source (all-the-plugins). Reached by tapping
/// its row in the unified Updates "Sources" list — this is the only place the per-file
/// diff list (potentially 50-300+ rows) is allowed to render, keeping the parent
/// dashboard's height constant regardless of how large the pending diff is.
struct PluginUpdatesDetailView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject var updater: PluginUpdater
    @State private var showReleasePicker = false
    @State private var expandedCategories: Set<String> = []   // collapsed by default
    @State private var incompatibleExpanded = false

    var body: some View {
        CardScroll {
            SectionCard(title: "Community apps", systemImage: "shippingbox",
                        accessory: AnyView(StatusPill(
                            text: transfer.activeChannel.label,
                            color: transfer.activeChannel == .usb ? .blue : .secondary,
                            systemImage: transfer.activeChannel.systemImage))) {
                statusRow
                HStack(spacing: 10) {
                    if showInlineCheck {
                        PillButton(title: "Check", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await updater.check() }
                        }
                        .disabled(busy)
                    }
                    if updater.canVerifyOnDevice {
                        PillButton(title: "Verify on device", systemImage: "checkmark.seal", tint: .secondary) {
                            Task { await updater.verifyInstalled() }
                        }
                        .disabled(busy || !hasFileChannel)
                    }
                }
            }

            releaseCard

            if updater.phase == .needsBaseline { baselineCard }

            if !updater.updates.isEmpty { changedCard }

            if updater.verifyResult != nil || updater.lastCleanup != nil { lastRunCard }
        }
        .navigationTitle("Community apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { HistoryView(updater: updater) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await updater.check() } } label: {
                        Label("Check now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        updater.resetBaseline()
                        Task { await updater.check() }   // forces the baseline choice → re-scan
                    } label: {
                        Label("Reset baseline / re-scan Flipper", systemImage: "arrow.clockwise.circle")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(busy)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if case .installing = updater.phase {
                VStack(spacing: 6) {
                    Button(role: .destructive) { updater.requestStop() } label: {
                        Label(updater.stopRequested ? "Stopping after current app…" : "Stop install",
                              systemImage: "stop.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(updater.stopRequested)
                    Text("Stopping keeps every app on its current working version — a half-written update is discarded, never applied. Only fully verified apps are installed.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(.bar)
            } else if updater.selectedCount > 0, !busy {
                VStack(spacing: 6) {
                    Button {
                        Task { await updater.install() }
                    } label: {
                        Label("Install \(updater.selectedCount) selected via \(transfer.activeChannel.label)",
                              systemImage: "square.and.arrow.down.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasFileChannel || ble.state != .ready || updater.validating)
                }
                .padding()
                .background(.bar)
            }
        }
        .onAppear { if case .idle = updater.phase, updater.updates.isEmpty { Task { await updater.check() } } }
        .task(id: ble.state) {
            if !updater.catalogMeta.isEmpty { await updater.validateCompatibility() }
        }
        .sheet(isPresented: $showReleasePicker) {
            NavigationStack { PluginReleasePickerView(updater: updater) }
        }
    }

    /// xMasterX occasionally ships a same-day follow-up build (tag suffixed p2, p3, …)
    /// when the first cut needed a fix — "Auto" (GitHub's own "latest") should track that,
    /// but this lets you pin an exact release if Auto hasn't picked it up yet, or to roll
    /// back deliberately.
    private var releaseCard: some View {
        CollapsibleCard(title: "Release", systemImage: "tag",
                        accessory: AnyView(StatusPill(
                            text: updater.manualReleaseTag ?? "Auto",
                            color: updater.manualReleaseTag == nil ? .secondary : .orange,
                            systemImage: updater.manualReleaseTag == nil ? "wand.and.stars" : "pin.fill"))) {
            Text(updater.manualReleaseTag == nil
                 ? "Using GitHub's latest all-the-plugins release automatically."
                 : "Pinned to \(updater.manualReleaseTag ?? "") — won't move to a newer release until you switch back to Auto.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "Choose release…", systemImage: "list.bullet") {
                showReleasePicker = true
            }
        }
    }

    /// Inline re-check button: shown once a check has finished (done/failed/baseline),
    /// hidden while idle (onAppear auto-checks) or busy. The toolbar always has "Check now".
    private var showInlineCheck: Bool {
        if case .idle = updater.phase { return false }
        return !busy
    }

    /// Bulk-selection menu, used as the changed-card's header accessory.
    private var selectMenu: some View {
        Menu {
            Button("Select all") { select { _ in true } }
            Button("Deselect all") { select { _ in false } }
            Divider()
            Button("Only new") { select(\.isNew) }
            Button("Only updates") { select { !$0.isNew } }
            Divider()
            Button("Only base pack") { select { $0.pack == "base" } }
            Button("Only extra pack") { select { $0.pack == "extra" } }
        } label: {
            HStack(spacing: 4) {
                Text("\(updater.selectedCount)/\(updater.installableUpdates.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "checklist").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    private var hasFileChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private var busy: Bool {
        if updater.validating { return true }
        switch updater.phase {
        case .fetching, .downloading, .scanning, .installing, .verifying: return true
        default: return false
        }
    }

    private var baselineCard: some View {
        SectionCard(title: "First sync", systemImage: "magnifyingglass") {
            Text("First sync (\(updater.tag)). Set a baseline so future checks show only what xMasterX changed:")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PillButton(title: "Scan Flipper (accurate)", systemImage: "magnifyingglass") {
                Task { await updater.scanBaseline() }
            }.disabled(!hasFileChannel)
            PillButton(title: "This build is already installed", systemImage: "checkmark.circle", tint: .secondary) {
                updater.seedBaseline()
            }
            Text("Pick “already installed” if you just flashed this pack via SD card — it skips the slow per-app scan.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var changedCard: some View {
        SectionCard(title: "\(updater.updates.count) changed · \(updater.tag)",
                    systemImage: "checklist", accessory: AnyView(selectMenu)) {
            if updater.changedFromScan > 0 {
                Label("\(updater.changedFromScan) app\(updater.changedFromScan == 1 ? "" : "s") differ from the pack (marked UPD) — may be YOUR modified builds, left unticked. Long-press a row → Protect to keep yours.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(spacing: 8) {
                ForEach(installCategories, id: \.self) { category in
                    categorySection(category)
                }
                if !updater.blockedUpdates.isEmpty { incompatibleSection }
            }
        }
    }

    /// Whether the consolidated "Last run" card should open expanded — only when there's
    /// something that actually needs a look (a failed verify, or a duplicate kept for
    /// manual review), not just routine "everything's fine" output.
    private var lastRunNeedsAttention: Bool {
        if let vr = updater.verifyResult, !vr.ok { return true }
        if let cl = updater.lastCleanup, !cl.kept.isEmpty { return true }
        return false
    }

    /// Combines the last install's signature verification and legacy-duplicate cleanup
    /// into one card instead of two, since they're both "what happened last time".
    private var lastRunCard: some View {
        CollapsibleCard(title: "Last run",
                        systemImage: lastRunNeedsAttention ? "exclamationmark.triangle.fill" : "checkmark.seal",
                        accessory: AnyView(lastRunPills), startExpanded: lastRunNeedsAttention) {
            if let vr = updater.verifyResult {
                Text((vr.kind == .onDevice ? "Device verification" : "Install").uppercased())
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).tracking(0.5)
                verifyDetail(vr)
            }
            if let cl = updater.lastCleanup {
                if updater.verifyResult != nil { Divider() }
                Text("Cleanup".uppercased())
                    .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary).tracking(0.5)
                cleanupDetail(cl)
            }
        }
    }

    private var lastRunPills: some View {
        HStack(spacing: 6) {
            if let vr = updater.verifyResult { verifyPills(vr) }
            if let cl = updater.lastCleanup { cleanupPills(cl) }
        }
    }

    private func verifyPills(_ vr: VerifyResult) -> some View {
        HStack(spacing: 6) {
            Text("\(vr.verified)✓").font(.caption).foregroundStyle(.green)
            if !vr.ok { Text("\(vr.failed.count)✗").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func cleanupPills(_ cl: CleanupResult) -> some View {
        HStack(spacing: 6) {
            if !cl.removed.isEmpty { Text("\(cl.removed.count) removed").font(.caption).foregroundStyle(.green) }
            if !cl.kept.isEmpty { Text("\(cl.kept.count) kept").font(.caption).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private func cleanupDetail(_ cl: CleanupResult) -> some View {
        if !cl.removed.isEmpty {
            Text("Removed legacy duplicate\(cl.removed.count == 1 ? "" : "s") (exact pack match):")
                .font(.caption2).foregroundStyle(.secondary)
            Text(cl.removed.prefix(12).joined(separator: "\n") + (cl.removed.count > 12 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !cl.kept.isEmpty {
            Text("Kept legacy file\(cl.kept.count == 1 ? "" : "s") for review (md5 differs — possible custom/older build):")
                .font(.caption2).foregroundStyle(.secondary)
            Text(cl.kept.prefix(12).joined(separator: "\n") + (cl.kept.count > 12 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func verifyDetail(_ vr: VerifyResult) -> some View {
        HStack(spacing: 8) {
            StatusPill(text: "\(vr.verified) verified", color: .green, systemImage: "checkmark.circle.fill")
            if !vr.ok {
                StatusPill(text: "\(vr.failed.count) failed", color: .orange, systemImage: "xmark.circle.fill")
            }
            Spacer()
            Text(vr.tag).font(.caption2).foregroundStyle(.secondary)
        }
        if !vr.ok {
            Text(vr.failed.prefix(8).joined(separator: "\n") + (vr.failed.count > 8 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Listed below — tap Install to (re)install them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Distinct install-location categories (the `/ext/apps/<category>/` folder each
    /// app actually lands in), alphabetical, with the uncategorised bucket last.
    private var installCategories: [String] {
        Set(updater.installableUpdates.map(\.targetCategory)).sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// One install-category section: collapsed by default. The header has TWO tap
    /// targets — a checkbox that selects/deselects the whole category (skip e.g. Games
    /// in one tap), and the rest of the row which expands to reveal each app's own
    /// toggle. Kept as sibling buttons so the checkbox tap never triggers expand.
    @ViewBuilder private func categorySection(_ category: String) -> some View {
        let items = updater.installableUpdates.filter { $0.targetCategory == category }
        let sel = items.filter(\.selected).count
        let box = sel == 0 ? "square" : (sel == items.count ? "checkmark.square.fill" : "minus.square.fill")
        let isOpen = expandedCategories.contains(category)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { setSelected(sel < items.count, inCategory: category) } label: {
                    Image(systemName: box)
                        .font(.body)
                        .foregroundStyle(sel == 0 ? Color.secondary : Theme.accent)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.snappy) { toggleExpanded(category) }
                } label: {
                    HStack(spacing: 6) {
                        Text(category.isEmpty ? "Other" : category)
                            .font(.subheadline).fontWeight(.medium)
                        Text("\(sel)/\(items.count)")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isOpen {
                ForEach(items) { u in
                    row(for: u)
                        .padding(.leading, 28)
                        .contextMenu {
                            Button { updater.addExclusion(u.name) } label: {
                                Label("Protect (never update)", systemImage: "lock")
                            }
                        }
                }
            }
            Divider().opacity(0.25)
        }
    }

    private func toggleExpanded(_ category: String) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }

    private func setSelected(_ selected: Bool, inCategory category: String) {
        updater.setSelected(selected) { $0.targetCategory == category }
    }

    private var incompatibleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { incompatibleExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text("Incompatible").font(.subheadline).fontWeight(.medium)
                    Text("\(updater.blockedUpdates.count)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Image(systemName: incompatibleExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if incompatibleExpanded {
                ForEach(updater.blockedUpdates) { update in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.name).font(.subheadline)
                            Text(updater.reason(update) ?? FapCompatibility.unknownDeviceReason)
                                .font(.caption2).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(update.pack == "base" ? "BASE" : "EXTRA")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)
                }
            }
            Divider().opacity(0.25)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle:
            if updater.updates.isEmpty {
                Label("Tap to check for updates", systemImage: "shippingbox").foregroundStyle(.secondary)
            }
        case .needsBaseline: EmptyView()
        case .fetching:    progress("Checking GitHub…")
        case .downloading: progress("Downloading packs…")
        case .scanning(let i, let n): progress("Scanning via \(transfer.activeChannel.label)… \(i)/\(n)")
        case .verifying(let i, let n): progress("Verifying on device… \(i)/\(n)")
        case .installing(let i, let n): installingRow(i, n)
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack { ProgressView(); Text(text).foregroundStyle(.secondary) }
    }

    /// Live install row: app counter + the current file's name and a real byte
    /// progress bar, so it's obvious it's moving (not hung).
    @ViewBuilder private func installingRow(_ i: Int, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView().scaleEffect(0.85)
                Text("Installing via \(updater.installDetail?.channel.label ?? transfer.activeChannel.label) \(i)/\(n)")
                    .foregroundStyle(.secondary)
            }
            if let d = updater.installDetail {
                HStack {
                    Text(d.name).font(.caption).lineLimit(1)
                    if d.attempt > 1 {
                        Spacer()
                        Text("retry \(d.attempt)").font(.caption2).foregroundStyle(.orange)
                    }
                }
                ProgressView(value: Double(d.sent), total: Double(max(d.total, 1)))
                    .tint(.orange)
                Text("\(byteStr(d.sent)) / \(byteStr(d.total))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func byteStr(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Row for one update, keyed and looked up by `id` rather than a `ForEach($array)`
    /// positional Binding. `updater.updates` shrinks the moment an install/exclusion
    /// completes (`removeAll`/reassignment); a `ForEach($array)`-projected Binding can
    /// still be resolving a now-stale index at that exact moment (SwiftUI keeps the
    /// screen "warm" even one level back in the nav stack), which trapped with an
    /// out-of-bounds Array subscript inside SwiftUI's own Toggle/ForEach machinery. An
    /// id-based lookup Binding just no-ops if the item is already gone instead of
    /// crashing — this is by VALUE (a snapshot for this render), the Binding is the
    /// only thing that reaches back into the live array, and only by id, never by index.
    private func row(for u: PluginUpdate) -> some View {
        Toggle(isOn: selectionBinding(for: u.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.name).font(.subheadline)
                    Text(updateSubtitle(u))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(u.isNew ? "NEW" : "UPD")
                        .font(.caption2).bold()
                        .foregroundStyle(u.isNew ? .green : .orange)
                    Text(byteStr(u.size))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectionBinding(for id: PluginUpdate.ID) -> Binding<Bool> {
        Binding(
            get: { updater.updates.first { $0.id == id }?.selected ?? false },
            set: { updater.setSelected($0, id: id) }
        )
    }

    private func updateSubtitle(_ update: PluginUpdate) -> String {
        // The install category is now the section header, so the row shows the
        // orthogonal context: which pack it came from (and its original folder if
        // the installer re-routes it somewhere else).
        var s = update.pack == "base" ? "Base pack" : "Extra pack"
        if update.isRouted { s += " · from \(update.category)" }
        return s
    }

    /// Set each row's selection to whether it matches the predicate.
    private func select(_ match: (PluginUpdate) -> Bool) {
        updater.selectOnly(where: match)
    }
}

/// Lets you pin all-the-plugins to an exact GitHub release instead of always trusting
/// "latest" — the escape hatch for a same-day follow-up build (tag suffixed p2, p3, …)
/// that Auto hasn't reflected yet, or for deliberately rolling back.
struct PluginReleasePickerView: View {
    @ObservedObject var updater: PluginUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    updater.setManualReleaseTag(nil)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto").foregroundStyle(.primary)
                            Text("Always use GitHub's latest release")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if updater.manualReleaseTag == nil {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                if updater.loadingReleases && updater.availableReleases.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if updater.availableReleases.isEmpty {
                    Text("Couldn't load releases from GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(updater.availableReleases) { release in
                    Button {
                        updater.setManualReleaseTag(release.tag)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(release.tag).foregroundStyle(release.hasPacks ? .primary : .secondary)
                                Text(release.publishedAt, style: .date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !release.hasPacks {
                                Text("no packs").font(.caption2).foregroundStyle(.orange)
                            } else if updater.manualReleaseTag == release.tag {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!release.hasPacks)
                }
            } header: {
                Text("Recent releases")
            } footer: {
                Text("xMasterX occasionally ships a same-day follow-up (tag suffixed p2, p3, …) — pick it here if Auto hasn't picked it up yet.")
            }
        }
        .navigationTitle("Release")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .refreshable { await updater.loadAvailableReleases() }
        .task { if updater.availableReleases.isEmpty { await updater.loadAvailableReleases() } }
    }
}
