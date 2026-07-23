import SwiftUI

/// Detail screen for the "Firmware packages" source (tumoflip SD packages). Reached by
/// tapping its row in the unified Updates "Sources" list. Lets the user pick Base / ARF /
/// Module One / Protocol Pack groups from the latest release and installs them with
/// staging, on-device verification, and rollback. Firmware DFU flashing is a separate
/// flow and is intentionally not offered here.
struct TumoflipUpdaterView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject var updater: TumoflipUpdater
    @State private var expanded: Set<String> = []
    @State private var pendingOverride: TumoflipFirmwareChannel?
    @State private var showHelp = false

    private let groupLabels: [(key: String, title: String, icon: String)] = [
        ("base", "Base", "shippingbox.fill"),
        ("arf", "ARF Sub-GHz", "car.fill"),
        ("module_one", "Module One", "square.grid.2x2.fill"),
        ("protocol_packs", "Protocol Packs", "antenna.radiowaves.left.and.right"),
    ]

    var body: some View {
        CardScroll {
            SectionCard(title: "Firmware packages", systemImage: "cpu.fill",
                        accessory: AnyView(StatusPill(
                            text: transfer.activeChannel.label,
                            color: transfer.activeChannel == .usb ? .blue : .secondary,
                            systemImage: transfer.activeChannel.systemImage))) {
                statusRow
                verifyRow
            }

            channelCard

            if updater.manifest != nil { groupsCard }
        }
        .navigationTitle("Firmware packages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("FW Packages help")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if updater.busy {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            await updater.reload(recover: hasFileChannel)
                            await updater.validateCompatibility()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { installBar }
        .onAppear {
            if updater.manifest == nil {
                Task { await updater.reload(recover: hasFileChannel) }
            }
        }
        .onChange(of: ble.state) { state in
            guard state == .ready else { return }
            Task { await updater.validateCompatibility() }
        }
        .sheet(isPresented: $showHelp) { TumoflipPackagesHelpView() }
        .confirmationDialog(
            "Switch package channel?",
            isPresented: Binding(
                get: { pendingOverride != nil },
                set: { if !$0 { pendingOverride = nil } }
            ),
            presenting: pendingOverride
        ) { channel in
            Button("Use \(channel.label) packages", role: channel == .dev ? .destructive : nil) {
                Task {
                    updater.setManualChannelOverride(channel)
                    await updater.reload(recover: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { channel in
            Text("This overrides the channel inferred from the installed firmware and will reload \(channel.packageLabel). Install only if the connected Flipper is compatible.")
        }
    }

    private var hasFileChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private var groupsCard: some View {
        SectionCard(title: "Package groups · \(updater.releaseTag)", systemImage: "shippingbox") {
            LazyVStack(spacing: 14) {
                ForEach(groupLabels, id: \.key) { g in
                    groupRow(g)
                }
            }
            if updater.compatibilityChecked && updater.hasUnvalidatedBinaries {
                Label(FapCompatibility.unknownDeviceReason, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !updater.hasPackageZip {
                Label("This release has the manifest but no install archive (tumoflip-packages.zip) yet — installing isn't available until a release publishes it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A dirty commit or routing warning is worth surfacing without a tap; a clean auto-detected channel isn't.
    private var channelNeedsAttention: Bool {
        updater.firmwareRoute.warning != nil || updater.deviceIdentity?.firmwareCommitDirty == true
    }

    private var channelCard: some View {
        CollapsibleCard(
            title: "Package channel",
            systemImage: "point.3.connected.trianglepath.dotted",
            accessory: AnyView(StatusPill(
                text: updater.firmwareRoute.channel.label,
                color: channelColor(updater.firmwareRoute.channel),
                systemImage: channelIcon(updater.firmwareRoute.channel)
            )),
            startExpanded: channelNeedsAttention
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if updater.deviceIdentity?.firmwareCommitDirty == true {
                    Label("Installed firmware reports a dirty commit; package compatibility should be treated as higher risk.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = updater.firmwareRoute.warning {
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Auto") {
                        Task {
                            updater.clearManualChannelOverride()
                            await updater.reload(recover: false)
                        }
                    }
                    .disabled(updater.manualChannelOverride == nil || updater.busy)

                    Button("Stable") { pendingOverride = .stable }
                        .disabled(updater.busy || updater.manualChannelOverride == .stable)
                    Button("Dev") { pendingOverride = .dev }
                        .disabled(updater.busy || updater.manualChannelOverride == .dev)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Divider().opacity(0.4)
                metadataRow("Installed", updater.deviceIdentity?.firmwareVersion ?? "Unknown")
                metadataRow("Origin", updater.deviceIdentity?.originFork ?? "Unknown")
                metadataRow("Detected", updater.firmwareRoute.detectedChannel?.packageLabel ?? "Unknown")
                metadataRow("Selected", updater.firmwareRoute.channel.packageLabel)
                if let manifest = updater.manifest {
                    metadataRow("Target package", "\(manifest.firmware.version) · \(updater.releaseTag)")
                    metadataRow("Package API", manifest.firmware.api)
                }
                if let api = updater.deviceIdentity?.firmwareAPI {
                    metadataRow("Installed API", api)
                }
                if let commit = updater.deviceIdentity?.firmwareCommit, !commit.isEmpty {
                    metadataRow("Commit", commit)
                }
            }
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func groupRow(_ g: (key: String, title: String, icon: String)) -> some View {
        let n = updater.count(g.key)
        let sel = updater.selectedCount(g.key)
        let selectable = updater.selectableCount(g.key)
        let cleanupEntries = updater.cleanupEntries(g.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                // Tri-state category checkbox: selects/deselects every file in the group.
                Button { updater.setGroup(g.key, selected: sel < selectable) } label: {
                    Image(systemName: sel == 0 ? "square" : (sel == selectable ? "checkmark.square.fill" : "minus.square.fill"))
                        .font(.title3)
                        .foregroundStyle(sel == 0 ? Color.secondary : Theme.accent)
                        .frame(width: 28, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectable == 0 || updater.busy || updater.validating)

                Image(systemName: g.icon).foregroundStyle(.orange).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title).font(.subheadline)
                    Text("\(sel)/\(selectable) compatible · \(byteStr(updater.bytes(g.key)))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if !cleanupEntries.isEmpty {
                        Label(
                            "\(cleanupEntries.count) legacy \(cleanupEntries.count == 1 ? "file" : "files") to remove",
                            systemImage: "trash.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    } else if let info = statusInfo(updater.status(g.key)) {
                        Label(info.text, systemImage: info.icon)
                            .font(.caption2).foregroundStyle(info.color)
                            .labelStyle(.titleAndIcon).lineLimit(1)
                    }
                }
                Spacer()
                if n > 0 {
                    Button {
                        withAnimation { toggleExpanded(g.key) }
                    } label: {
                        Image(systemName: expanded.contains(g.key) ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
            if expanded.contains(g.key) {
                VStack(spacing: 6) {
                    ForEach(updater.files(g.key), id: \.target) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: fileBinding(f.target)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").font(.caption2).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(fileName(f.target))
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        fileStatusLabel(updater.status(file: f.target))
                                    }
                                    Spacer()
                                    Text(byteStr(f.bytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .tint(Theme.accent)
                            .disabled(updater.busy || updater.validating || updater.isFileBlocked(f.target))
                            .accessibilityLabel(fileName(f.target))
                            .accessibilityValue(fileStatusInfo(updater.status(file: f.target)).text)
                            if let reason = updater.blocked[f.target] {
                                Label(reason, systemImage: "exclamationmark.octagon.fill")
                                    .font(.caption2).foregroundStyle(.red)
                                    .labelStyle(.titleAndIcon)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 28)
                    }
                    ForEach(cleanupEntries, id: \.legacy) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "trash.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Cleanup required")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(entry.legacy)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 28)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Cleanup required")
                        .accessibilityValue(entry.legacy)
                    }
                }
            }
            if g.key != groupLabels.last?.key { Divider() }
        }
    }

    private func fileBinding(_ target: String) -> Binding<Bool> {
        Binding(get: { updater.isFileSelected(target) },
                set: { updater.setFile(target, selected: $0) })
    }

    private var selectedFileCount: Int { updater.selectedFileCount }

    @ViewBuilder private var installBar: some View {
        if case .installing = updater.phase {
            VStack(spacing: 6) {
                Button(role: .destructive) { updater.requestStop() } label: {
                    Label(updater.stopRequested ? "Stopping — rolling back…" : "Stop install",
                          systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(updater.stopRequested)
            }
            .padding()
            .background(.bar)
        } else if updater.manifest != nil, updater.hasPackageZip, selectedFileCount > 0, !updater.busy {
            VStack(spacing: 6) {
                if updater.selectedRequiresCompatibilityIdentity && !updater.hasFreshCompatibilityIdentity {
                    Label("Connect Flipper over BLE to validate apps before installing via \(transfer.activeChannel.label).",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.caption2).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { Task { await updater.install() } } label: {
                    Label("Install \(selectedFileCount) file\(selectedFileCount == 1 ? "" : "s")",
                          systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(
                    !hasFileChannel || updater.validating ||
                    (updater.selectedRequiresCompatibilityIdentity && !updater.hasFreshCompatibilityIdentity))
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle, .ready:
            if updater.manifest == nil {
                Label("Tap refresh to check the latest release", systemImage: "shippingbox").foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Latest: \(updater.releaseTag)", systemImage: "shippingbox").foregroundStyle(.secondary)
                    Spacer()
                    if let info = statusInfo(updater.overallStatus) {
                        StatusPill(text: info.text, color: info.color, systemImage: info.icon)
                    }
                }
            }
        case .checking:    progress("Checking the latest release…")
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                progress("Downloading package archive…")
                keepAwakeNote
            }
        case .installing(let done, let total, let file):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(file) · \(updater.transferChannel.label)")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(Double(done) / Double(max(total, 1)) * 100))%")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                keepAwakeNote
            }
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

    /// Shown during a live transaction: locking the phone mid-install tears down BLE.
    private var keepAwakeNote: some View {
        Label(transfer.activeChannel == .usb
              ? "Keep USB SD Mode active on the Flipper until this finishes."
              : "Keep the screen on and the app open — don't lock your phone until this finishes.",
              systemImage: transfer.activeChannel == .usb ? "cable.connector" : "lock.open.iphone")
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// On-demand deep check: hash the actual files on the Flipper to confirm presence/integrity.
    @ViewBuilder private var verifyRow: some View {
        if updater.manifest != nil {
            Button {
                Task { await updater.verifyOnDevice() }
            } label: {
                HStack {
                    if updater.verifying {
                        ProgressView().scaleEffect(0.85)
                        Text("Verifying on device…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.shield")
                        Text("Verify on device")
                    }
                    Spacer()
                    if updater.lastVerifiedOnDevice && !updater.verifying {
                        Label("device-checked", systemImage: "checkmark.seal.fill")
                            .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                    }
                }
            }
            .disabled(updater.verifying || !hasFileChannel)
        }
    }

    private func byteStr(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    private func toggleExpanded(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func fileName(_ target: String) -> String { (target as NSString).lastPathComponent }

    private func fileStatusLabel(_ status: TumoflipInstaller.FileStatus) -> some View {
        let info = fileStatusInfo(status)
        return Label(info.text, systemImage: info.icon)
            .font(.caption2)
            .foregroundStyle(info.color)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }

    private func fileStatusInfo(
        _ status: TumoflipInstaller.FileStatus
    ) -> (text: String, color: Color, icon: String) {
        switch status {
        case .upToDate:
            return ("Up to date", .green, "checkmark.circle.fill")
        case .needsUpdate:
            return ("Needs update", .orange, "arrow.down.circle.fill")
        case .missing:
            return ("Missing", .secondary, "questionmark.folder.fill")
        case .unknown:
            return ("Unknown", .secondary, "questionmark.circle")
        case .validationError:
            return ("Validation error", .red, "exclamationmark.triangle.fill")
        }
    }

    private func channelColor(_ channel: TumoflipFirmwareChannel) -> Color {
        switch channel {
        case .stable: return .green
        case .dev: return .purple
        }
    }

    private func channelIcon(_ channel: TumoflipFirmwareChannel) -> String {
        switch channel {
        case .stable: return "checkmark.seal.fill"
        case .dev: return "hammer.fill"
        }
    }

    /// Display mapping for a group/overall status. `nil` for `.empty` (no badge).
    private func statusInfo(_ s: TumoflipInstaller.GroupStatus) -> (text: String, color: Color, icon: String)? {
        switch s {
        case .upToDate:        return ("Up to date", .green, "checkmark.circle.fill")
        case .updateAvailable: return ("Update available", .orange, "arrow.down.circle.fill")
        case .notInstalled:    return ("Not installed", .secondary, "circle.dashed")
        case .empty:           return nil
        }
    }
}

private struct TumoflipPackagesHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("FW Packages update Tumoflip apps, resources, and protocol packs on the SD card.",
                      systemImage: "shippingbox")
                Label("The channel follows the installed Stable or Dev firmware unless you override it.",
                      systemImage: "point.3.connected.trianglepath.dotted")
                Label("Files are staged, verified, and rolled back if installation fails.",
                      systemImage: "checkmark.shield")
                Label("Verify on device checks the files currently stored on the Flipper.",
                      systemImage: "checkmark.seal")
                Label("Keep the app open during BLE transfer or USB SD Mode active during USB transfer.",
                      systemImage: "arrow.left.arrow.right")
            }
            .navigationTitle("FW Packages help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
