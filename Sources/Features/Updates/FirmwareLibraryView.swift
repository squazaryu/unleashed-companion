import SwiftUI

struct FirmwareLibraryView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var transfer: TransferChannelStore
    @ObservedObject var library: FirmwareLibrary
    @State private var showHelp = false
    @State private var pendingRelease: FirmwareRelease?
    @State private var detailsRelease: FirmwareRelease?

    var body: some View {
        CardScroll {
            connectionCard
            channelPicker
            if library.visibleGroups.isEmpty {
                emptyCard
            } else {
                ForEach(Array(library.visibleGroups.enumerated()), id: \.element.id) { index, group in
                    versionGroupCard(group, startExpanded: index == 0)
                }
            }
        }
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Firmware help")
                Button { library.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(library.busy)
                .accessibilityLabel("Refresh firmware releases")
            }
        }
        .safeAreaInset(edge: .bottom) { progressBar }
        .sheet(isPresented: $showHelp) { FirmwareHelpView() }
        .sheet(item: $detailsRelease) { FirmwareReleaseDetailsView(release: $0) }
        .confirmationDialog(
            "Prepare this firmware?",
            isPresented: Binding(
                get: { pendingRelease != nil },
                set: { if !$0 { pendingRelease = nil } }
            ),
            presenting: pendingRelease
        ) { release in
            Button("Prepare \(release.version)") {
                Task { await library.stage(release) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { release in
            Text("The verified updater will be copied to Archive > update. Installation still starts on the Flipper.")
        }
    }

    private var connectionCard: some View {
        SectionCard(
            title: "Ready to transfer",
            systemImage: "arrow.down.to.line.compact",
            accessory: AnyView(StatusPill(
                text: transfer.activeChannel.label,
                color: transfer.activeChannel == .usb ? .blue : .secondary,
                systemImage: transfer.activeChannel.systemImage
            ))
        ) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.installedVersion ?? "Flipper not identified")
                        .font(.subheadline).fontWeight(.semibold)
                    if let api = library.installedAPI {
                        Text("API \(api)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                phasePill
            }
        }
    }

    private var channelPicker: some View {
        Picker("Channel", selection: Binding(
            get: { library.selectedChannel },
            set: { library.setChannel($0) }
        )) {
            Text("Main").tag(TumoflipFirmwareChannel.stable)
            Text("Dev").tag(TumoflipFirmwareChannel.dev)
        }
        .pickerStyle(.segmented)
        .disabled(library.busy)
    }

    private var emptyCard: some View {
        SectionCard(title: "No releases", systemImage: "tray") {
            HStack(spacing: 10) {
                if library.busy { ProgressView() }
                Text(emptyMessage)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyMessage: String {
        if library.busy { return "Loading releases..." }
        if library.selectedChannel == .dev {
            return "No Dev builds have been published after the latest Main release."
        }
        return "No Main firmware releases found."
    }

    private func versionGroupCard(
        _ group: FirmwareVersionGroup,
        startExpanded: Bool
    ) -> some View {
        CollapsibleCard(
            title: "Version \(group.line)",
            systemImage: library.selectedChannel == .dev ? "hammer.fill" : "checkmark.seal.fill",
            accessory: AnyView(
                Text("\(group.releases.count) \(group.releases.count == 1 ? "build" : "builds")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            ),
            contentSpacing: 7,
            cardPadding: 12,
            startExpanded: startExpanded
        ) {
            VStack(spacing: 0) {
                ForEach(Array(group.releases.enumerated()), id: \.element.id) { index, release in
                    compactReleaseRow(release, isLatest: index == 0 && group.id == library.visibleGroups.first?.id)
                    if index < group.releases.count - 1 {
                        Divider().padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func compactReleaseRow(_ release: FirmwareRelease, isLatest: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(release.buildLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if library.installedVersion == release.version {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if isLatest {
                        Text("Latest")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(releaseMetadata(release))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            HStack(spacing: 0) {
                Button { detailsRelease = release } label: {
                    compactActionIcon(
                        "info.circle",
                        foreground: Theme.accent,
                        background: Theme.accent.opacity(0.12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(release.version)")

                Button { pendingRelease = release } label: {
                    compactActionIcon(
                        "arrow.down.to.line.compact",
                        foreground: .white,
                        background: Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(library.busy || !hasTransferChannel)
                .accessibilityLabel(
                    library.installedVersion == release.version
                        ? "Prepare \(release.version) again"
                        : "Prepare \(release.version)"
                )
            }
        }
        .padding(.vertical, 1)
    }

    private func compactActionIcon(
        _ systemName: String,
        foreground: Color,
        background: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: 32, height: 32)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }

    private func releaseMetadata(_ release: FirmwareRelease) -> String {
        let date = release.publishedAt.formatted(date: .abbreviated, time: .omitted)
        let size = ByteCountFormatter.string(fromByteCount: release.updaterSize, countStyle: .file)
        return "\(date) · \(size)"
    }

    private var hasTransferChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    @ViewBuilder private var phasePill: some View {
        switch library.phase {
        case .done:
            StatusPill(text: "Prepared", color: .green, systemImage: "checkmark.circle.fill")
        case .failed:
            StatusPill(text: "Error", color: .red, systemImage: "exclamationmark.triangle.fill")
        case .loading, .downloading, .verifying, .staging:
            ProgressView().scaleEffect(0.85)
        case .idle, .ready:
            StatusPill(text: "Ready", color: .secondary, systemImage: "circle")
        }
    }

    @ViewBuilder private var progressBar: some View {
        switch library.phase {
        case .downloading(let version, let fraction):
            transferProgress(title: "Downloading \(version)", fraction: fraction)
        case .verifying(let version):
            transferProgress(title: "Verifying \(version)", fraction: nil)
        case .staging(let version, let file, let done, let total):
            transferProgress(
                title: "\(version) · \(file)",
                fraction: total > 0 ? Double(done) / Double(total) : nil,
                canStop: true)
        case .done(let message):
            resultBar(message, color: .green, icon: "checkmark.circle.fill")
        case .failed(let message):
            resultBar(message, color: .red, icon: "exclamationmark.triangle.fill")
        default:
            EmptyView()
        }
    }

    private func transferProgress(title: String, fraction: Double?, canStop: Bool = false) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
            }
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
            if canStop {
                Button(role: .destructive) { library.requestStop() } label: {
                    Label(library.stopRequested ? "Stopping after this file" : "Stop",
                          systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(library.stopRequested)
            }
        }
        .padding()
        .background(.bar)
    }

    private func resultBar(_ message: String, color: Color, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.caption).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.bar)
    }
}

private struct FirmwareReleaseDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let release: FirmwareRelease

    var body: some View {
        NavigationStack {
            List {
                Section("Release") {
                    LabeledContent("Version", value: release.version)
                    LabeledContent(
                        "Channel",
                        value: release.channel == .stable ? "Main" : "Dev")
                    LabeledContent(
                        "Published",
                        value: release.publishedAt.formatted(date: .long, time: .shortened))
                    LabeledContent(
                        "Updater",
                        value: ByteCountFormatter.string(
                            fromByteCount: release.updaterSize, countStyle: .file))
                }
                if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Notes") {
                        Text(release.notes).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(release.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FirmwareHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("Choose Main or Dev, then select a release.", systemImage: "list.bullet")
                Label("Dev shows only builds published after the latest Main release.", systemImage: "clock.badge.checkmark")
                Label("The updater is verified with SHA-256 before transfer.", systemImage: "checkmark.shield")
                Label("Files are staged atomically; update.fuf is written last.", systemImage: "doc.badge.gearshape")
                Label("Start installation from Archive > update on the Flipper.", systemImage: "hand.tap")
            }
            .navigationTitle("Firmware help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct UpdatesHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("Firmware prepares a full Main or Dev updater.", systemImage: "memorychip")
                Label("FW Packages refresh Tumoflip apps and resources.", systemImage: "shippingbox")
                Label("Community apps installs compatible All The Plugins apps.", systemImage: "puzzlepiece.extension")
                Label("Keep the app open during BLE transfers.", systemImage: "iphone.radiowaves.left.and.right")
            }
            .navigationTitle("Updates help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
