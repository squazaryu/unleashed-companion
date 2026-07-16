import SwiftUI

struct ESP32FirmwareView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @StateObject private var up = ESP32Updater()
    @State private var expandedVersionGroups: Set<String> = []
    @State private var deleteTarget: ESP32Updater.Board?
    @State private var deleteAll = false
    @State private var deleteArchived = false

    var body: some View {
        CardScroll {
            statusCard
            ForEach(up.currentBoards) { b in boardCard(b) }
            if !up.versionGroups.isEmpty { versionManagerCard }
            if up.boards.isEmpty && up.archivedBoards.isEmpty && !up.busy { emptyCard }
        }
        .navigationTitle("ESP32 Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await up.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(up.busy)
            }
        }
        .task { if up.latestTag == nil { await up.refresh() } }
        .alert("Remove this folder?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let b = deleteTarget { Task { await up.delete(b) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Removes \(deleteTarget?.display ?? "") \(deleteTarget?.currentVersion ?? "") staged on the SD. The firmware already flashed on the ESP32 isn't affected.")
        }
        .alert("Delete all active older versions?", isPresented: $deleteAll) {
            Button("Delete \(up.olderBoards.count)", role: .destructive) { Task { await up.deleteOlder() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every outdated active flash folder from the SD, keeping the newest of each board. Archived folders are not affected.")
        }
        .alert("Delete archived versions?", isPresented: $deleteArchived) {
            Button("Delete \(up.archivedBoards.count)", role: .destructive) { Task { await up.deleteArchived() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every archived ESP32 flash folder from the SD. The firmware already flashed on the ESP32 isn't affected.")
        }
    }

    private var statusCard: some View {
        SectionCard(title: "ESP32 Marauder", systemImage: "cpu",
                    accessory: up.latestTag == nil ? nil : AnyView(
                        StatusPill(text: up.updateAvailable ? "Update" : "Latest",
                                   color: up.updateAvailable ? .orange : .green,
                                   systemImage: up.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle.fill"))) {
            HStack {
                Text("Latest release").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(up.latestTag ?? "—").font(.subheadline).fontWeight(.semibold)
            }
            if up.busy, let p = up.progress {
                ProgressView(value: p)
                if let d = up.progressText {
                    Text(d).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if up.busy {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Label("File channel", systemImage: currentChannel.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(
                    text: currentChannel.label,
                    color: currentChannel == .usb ? .blue : .secondary,
                    systemImage: currentChannel.systemImage
                )
            }
            if let s = up.status {
                Text(s).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Checks github.com/justcallmekoko/ESP32Marauder. Updating writes a new manual folder to the SD — flash it from the Flipper’s esp_flasher app.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each detected board key is updated separately. C5 and WROOM modules keep separate versioned folders.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func boardCard(_ b: ESP32Updater.Board) -> some View {
        let newer = up.newVersion(for: b)
        return SectionCard(title: b.display, systemImage: "memorychip",
                           accessory: AnyView(
                            StatusPill(text: newer ? "Update" : "Latest",
                                       color: newer ? .orange : .green,
                                       systemImage: newer ? "arrow.down.circle.fill" : "checkmark.circle.fill"))) {
            HStack {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(b.currentVersion).font(.caption).fontWeight(.medium)
            }
            if let tag = up.latestTag {
                HStack {
                    Text("Latest").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(tag).font(.caption).fontWeight(.medium)
                        .foregroundStyle(newer ? .orange : .green)
                }
            }
            Divider().opacity(0.4)
            if newer, let tag = up.latestTag {
                PillButton(title: "Update to \(tag) via \(currentChannel.label)", systemImage: "arrow.down.circle", tint: Theme.accent) {
                    Task { await up.install(b) }
                }
                .disabled(up.busy || !hasFileChannel)
            } else {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Text("Board key: \(b.key)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var currentChannel: TransferChannel {
        up.busy ? up.transferChannel : transfer.activeChannel
    }

    private var hasFileChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private var versionManagerCard: some View {
        CollapsibleCard(title: "Firmware versions", systemImage: "clock.arrow.circlepath",
                        accessory: AnyView(StatusPill(text: "\(up.versionGroups.count)", color: .secondary))) {
            Text("Choose a staged Marauder version per board key. Active folders are visible to esp_flasher; archived folders are hidden until restored.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !up.olderBoards.isEmpty {
                PillButton(title: "Archive all active older", systemImage: "archivebox", tint: Theme.accent) {
                    Task { await up.archiveOlder() }
                }
                .disabled(up.busy)
            }

            VStack(spacing: 10) {
                ForEach(up.versionGroups) { group in
                    DisclosureGroup(isExpanded: versionGroupBinding(group.key)) {
                        VStack(spacing: 8) {
                            if let current = group.current {
                                versionRow(current, location: .current)
                            }
                            ForEach(group.activeOlder) { board in
                                versionRow(board, location: .activeOlder)
                            }
                            ForEach(group.archived) { board in
                                versionRow(board, location: .archived)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.display)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(group.key)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(group.versions.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.secondary)
                }
            }

            HStack {
                if up.olderBoards.count > 1 {
                    Button(role: .destructive) { deleteAll = true } label: {
                        Label("Delete active older", systemImage: "trash").font(.caption)
                    }
                    .disabled(up.busy)
                }
                if up.archivedBoards.count > 1 {
                    Button(role: .destructive) { deleteArchived = true } label: {
                        Label("Delete archive", systemImage: "trash").font(.caption)
                    }
                    .disabled(up.busy)
                }
            }
        }
    }

    private enum VersionLocation {
        case current
        case activeOlder
        case archived

        var label: String {
            switch self {
            case .current: return "Active"
            case .activeOlder: return "Older"
            case .archived: return "Archived"
            }
        }

        var icon: String {
            switch self {
            case .current: return "checkmark.circle.fill"
            case .activeOlder: return "exclamationmark.circle"
            case .archived: return "archivebox"
            }
        }
    }

    private func versionRow(_ b: ESP32Updater.Board, location: VersionLocation) -> some View {
        HStack {
            Image(systemName: location.icon)
                .foregroundStyle(location == .current ? .green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.currentVersion).font(.subheadline)
                Text(location.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch location {
            case .current:
                Label("visible", systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .activeOlder:
                Button { Task { await up.archive(b) } } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
                Button(role: .destructive) { deleteTarget = b } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
            case .archived:
                Button { Task { await up.restore(b) } } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
                Button(role: .destructive) { deleteTarget = b } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
            }
        }
        .contentShape(Rectangle())
    }

    private func versionGroupBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedVersionGroups.contains(key) },
            set: { expanded in
                if expanded {
                    expandedVersionGroups.insert(key)
                } else {
                    expandedVersionGroups.remove(key)
                }
            }
        )
    }

    private var emptyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
            Text("No Marauder flash folders found under esp_flasher. Flash once with the Flipper’s esp_flasher app to create one, then updates land here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
