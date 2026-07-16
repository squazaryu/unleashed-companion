import SwiftUI

struct BackupView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var bk = FlipperBackup()
    @State private var folders: [String] = []
    @State private var selected: Set<String> = []
    @State private var shareItem: ShareImage?           // reuse the share wrapper (URL)
    @State private var restoreTarget: URL?

    var body: some View {
        CardScroll {
            if ble.state != .ready {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Connect to a Flipper to back up.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(tint: .orange)
            }

            SectionCard(title: "Folders to back up", systemImage: "folder") {
                if folders.isEmpty {
                    Text("Loading folders…").foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(folders, id: \.self) { f in
                    Button { toggle(f) } label: {
                        HStack {
                            Image(systemName: selected.contains(f) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(f) ? .orange : .secondary)
                            Text(f).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                }
                Text("apps / update are unticked by default — they're re-installable from the plugin pack.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionCard(title: "Create backup", systemImage: "arrow.down.circle") {
                PillButton(title: bk.running ? "Working…" : "Back up now", systemImage: "arrow.down.circle") {
                    Task { await bk.backup(folders: Array(selected), stamp: stamp()) }
                }
                .disabled(ble.state != .ready || bk.running || selected.isEmpty)
                if let s = bk.status {
                    HStack {
                        if bk.running { ProgressView().scaleEffect(0.8) }
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            SectionCard(title: "Backups (\(bk.backups.count))", systemImage: "externaldrive") {
                if bk.backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary).font(.footnote)
                }
                ForEach(Array(bk.backups.enumerated()), id: \.element) { index, url in
                    backupRow(url)
                    if index < bk.backups.count - 1 { Divider().opacity(0.4) }
                }
            }
        }
        .navigationTitle("Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
        .alert("Restore this backup?", isPresented: Binding(
            get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } })) {
            Button("Restore", role: .destructive) {
                if let u = restoreTarget { Task { await bk.restore(u) } }
                restoreTarget = nil
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        } message: {
            Text("Files in the backup will be written to the Flipper, overwriting any with the same path.")
        }
        .task {
            bk.refreshBackups()
            if ble.state == .ready, folders.isEmpty {
                folders = await bk.topLevelFolders()
                selected = Set(folders.filter { !FlipperBackup.excludedDefaults.contains($0) })
            }
        }
    }

    private func backupRow(_ url: URL) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(.footnote, design: .monospaced))
                Text(sizeString(url)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { shareItem = ShareImage(url: url) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
            Button { restoreTarget = url } label: { Image(systemName: "arrow.up.circle") }
                .buttonStyle(.borderless)
                .disabled(ble.state != .ready || bk.running)
            Button(role: .destructive) { bk.delete(url) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }

    private func toggle(_ f: String) {
        if selected.contains(f) { selected.remove(f) } else { selected.insert(f) }
    }

    private func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; return f.string(from: Date())
    }

    private func sizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
