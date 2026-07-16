import Foundation
import ZIPFoundation

/// Backs up selected Flipper SD folders to a timestamped .zip in the app's
/// Documents (over BLE), and restores a .zip back to the Flipper.
@MainActor
final class FlipperBackup: ObservableObject {
    @Published var running = false
    @Published var status: String?
    @Published var backups: [URL] = []

    private let storage = FlipperStorage()

    /// Top-level folders excluded from the default selection (large / re-installable).
    static let excludedDefaults: Set<String> = [
        "apps", "apps_assets", "apps_data", "apps_manifests", "update"
    ]

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func refreshBackups() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        backups = urls.filter { $0.pathExtension == "zip" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    /// Top-level folders on the SD, for the selection UI.
    func topLevelFolders() async -> [String] {
        let entries = (try? await storage.list("/ext")) ?? []
        return entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") }.map(\.name).sorted()
    }

    func backup(folders: [String], stamp: String) async {
        running = true; status = "Scanning…"; defer { running = false }
        var files: [String] = []
        for f in folders { await collect("/ext/\(f)", into: &files) }
        guard !files.isEmpty else { status = "Nothing to back up."; return }

        let url = Self.dir.appendingPathComponent("flipper-\(stamp).zip")
        try? FileManager.default.removeItem(at: url)
        guard let archive = Archive(url: url, accessMode: .create) else {
            status = "Couldn't create the backup archive."; return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bk-chunk")
        var done = 0
        for path in files {
            done += 1
            status = "Backing up \(done)/\(files.count)…"
            guard let data = try? await storage.read(path) else { continue }
            let rel = String(path.dropFirst("/ext/".count))
            try? data.write(to: tmp)
            try? archive.addEntry(with: rel, fileURL: tmp, compressionMethod: .deflate)
        }
        try? FileManager.default.removeItem(at: tmp)
        refreshBackups()
        status = "Backed up \(done) file\(done == 1 ? "" : "s")."
    }

    func restore(_ zipURL: URL) async {
        running = true; status = "Reading backup…"; defer { running = false }
        guard let archive = Archive(url: zipURL, accessMode: .read) else { status = "Bad archive."; return }
        let entries = archive.filter { $0.type == .file }
        var done = 0
        for entry in entries {
            done += 1
            status = "Restoring \(done)/\(entries.count)…"
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            let dest = "/ext/\(entry.path)"
            await makeDirs(for: dest)
            try? await storage.write(dest, data: data)
        }
        status = "Restored \(done) file\(done == 1 ? "" : "s")."
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshBackups()
    }

    // MARK: - Helpers

    private func collect(_ path: String, into files: inout [String]) async {
        let entries = (try? await storage.list(path)) ?? []
        for e in entries {
            if e.isDirectory { await collect(e.path, into: &files) }
            else { files.append(e.path) }
        }
    }

    /// Create every intermediate directory for a file path under /ext.
    private func makeDirs(for filePath: String) async {
        let comps = filePath.split(separator: "/").dropLast()   // drop filename
        var acc = ""
        for c in comps {
            acc += "/\(c)"
            try? await storage.makeDirectory(acc)
        }
    }
}
