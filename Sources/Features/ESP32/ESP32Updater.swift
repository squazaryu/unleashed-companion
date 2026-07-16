import Foundation
import CryptoKit
import os

private let elog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "esp32")

/// Checks the ESP32Marauder GitHub repo for new firmware and, on demand, writes a
/// NEW manual flash folder onto the Flipper SD under `/ext/apps_data/esp_flasher/`
/// so the user can flash it from the Flipper's esp_flasher app.
///
/// Marauder release assets are per-board APP images (flashed at 0x10000); the
/// bootloader/partitions/boot_app0 boot files are version-independent, so we reuse
/// them from the board's existing `*_manual` folder and only swap in the new app.
@MainActor
final class ESP32Updater: ObservableObject {
    struct Board: Identifiable, Equatable {
        let id = UUID()
        let folder: String        // existing manual folder path on SD
        let base: String          // folder name minus "_manual", e.g. "module_one_v6_1"
        let display: String       // clean board name (firmware-version suffix stripped)
        let key: String           // release board key, e.g. "v6_1" / "flipper" / "marauder_v7"
        let currentVersion: String // "v1.12.1"
        let appName: String        // existing app .bin name
        let bootFiles: [String]    // non-app .bin names to copy forward
    }

    struct BoardVersionGroup: Identifiable, Equatable {
        let key: String
        let display: String
        let current: Board?
        let activeOlder: [Board]
        let archived: [Board]

        var id: String { key }
        var versions: [Board] { ([current].compactMap { $0 } + activeOlder + archived) }
    }

    @Published private(set) var boards: [Board] = []
    @Published private(set) var archivedBoards: [Board] = []
    @Published private(set) var latestTag: String?     // e.g. "v1.12.2"
    @Published var status: String?
    @Published var busy = false
    @Published var progress: Double?
    /// Live "N% · done / total" caption shown directly under the progress bar,
    /// driven by both the WiFi download and the on-device write phases.
    @Published var progressText: String?
    @Published private(set) var transferChannel: TransferChannel = .ble

    /// True only while the GitHub download is streaming. Gates the download
    /// progress callback so a late `didWriteData` Task (queued during the
    /// download but drained after it) can't re-fill the bar or overwrite the
    /// status once the on-device write phase has taken over. Main-actor isolated.
    private var downloadPhase = false

    private var storage: any DeviceFileStore { TransferChannelStore.shared.activeStore }
    static let repo = "justcallmekoko/ESP32Marauder"
    static let flasherDir = "/ext/apps_data/esp_flasher"
    static let archiveDir = "\(flasherDir)/_archive"

    nonisolated static func norm(_ v: String) -> String {
        v.lowercased().replacingOccurrences(of: "v", with: "")
            .replacingOccurrences(of: "_", with: ".")
    }

    nonisolated static func versionParts(_ v: String) -> [Int] { norm(v).split(separator: ".").compactMap { Int($0) } }

    /// Numeric, component-wise newer test (so 1.12.10 > 1.12.2, not lexical).
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = versionParts(a), y = versionParts(b)
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    /// Strip a trailing firmware-version suffix (`_v1_12_2`) from a folder base, leaving
    /// the stable board name (`module_one_v6_1`). Board keys like `v6_1` (two parts) stay.
    nonisolated static func cleanBase(_ base: String) -> String {
        base.replacingOccurrences(of: "_v[0-9]+_[0-9]+_[0-9]+$", with: "", options: .regularExpression)
    }

    /// Newest staged folder per board key — the cards shown up top.
    var currentBoards: [Board] {
        Dictionary(grouping: boards, by: \.key).values.compactMap { group in
            group.sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }.first
        }.sorted { $0.display < $1.display }
    }

    /// Older staged folders (every folder except the newest of each board) — the archive.
    var olderBoards: [Board] {
        let keep = Set(currentBoards.map(\.id))
        return boards.filter { !keep.contains($0.id) }.sorted {
            $0.display == $1.display ? Self.isNewer($0.currentVersion, than: $1.currentVersion)
                                     : $0.display < $1.display
        }
    }

    /// True when any detected board's installed version differs from the latest release.
    var updateAvailable: Bool {
        guard let latest = latestTag else { return false }
        return currentBoards.contains { Self.norm($0.currentVersion) != Self.norm(latest) }
    }

    func newVersion(for board: Board) -> Bool {
        guard let latest = latestTag else { return false }
        return Self.norm(board.currentVersion) != Self.norm(latest)
    }

    var versionGroups: [BoardVersionGroup] {
        let activeCurrent = currentBoards
        let activeOlder = olderBoards
        let keys = Set((boards + archivedBoards).map(\.key))
        return keys.map { key in
            let current = activeCurrent.first { $0.key == key }
            let older = activeOlder
                .filter { $0.key == key }
                .sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }
            let archived = archivedBoards
                .filter { $0.key == key }
                .sorted { Self.isNewer($0.currentVersion, than: $1.currentVersion) }
            let display = current?.display ?? older.first?.display ?? archived.first?.display ?? key
            return BoardVersionGroup(
                key: key,
                display: display,
                current: current,
                activeOlder: older,
                archived: archived)
        }
        .sorted { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
    }

    /// Remove one staged flash folder from the SD (the flashed ESP32 is untouched).
    func delete(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.delete(board.folder, recursive: true)
            await scanBoards()
            status = "Removed \(board.display) \(board.currentVersion)."
        } catch { status = "Couldn't remove: \(error.localizedDescription)" }
    }

    /// Remove all older (non-newest) staged folders in one go.
    func deleteOlder() async {
        let targets = olderBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        var removed = 0
        for b in targets where (try? await storage.delete(b.folder, recursive: true)) != nil { removed += 1 }
        await scanBoards()
        status = "Cleaned up \(removed) old folder\(removed == 1 ? "" : "s")."
    }

    /// Move one staged flash folder into the ESP32 updater archive.
    func archive(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.makeDirectory(Self.archiveDir)
            let destination = await uniqueArchivePath(for: board)
            try await storage.move(board.folder, to: destination)
            await scanBoards()
            status = "Archived \(board.display) \(board.currentVersion)."
        } catch {
            status = "Couldn't archive: \(error.localizedDescription)"
        }
    }

    /// Move every older active folder out of the flasher root, keeping only newest boards visible.
    func archiveOlder() async {
        let targets = olderBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            try await storage.makeDirectory(Self.archiveDir)
            var moved = 0
            for board in targets {
                let destination = await uniqueArchivePath(for: board)
                do {
                    try await storage.move(board.folder, to: destination)
                    moved += 1
                } catch {
                    elog.error("archive \(board.folder, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            await scanBoards()
            status = "Archived \(moved) old folder\(moved == 1 ? "" : "s")."
        } catch {
            status = "Couldn't prepare archive: \(error.localizedDescription)"
        }
    }

    /// Restore an archived folder back into the esp_flasher root.
    func restore(_ board: Board) async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        do {
            let destination = await uniqueActivePath(for: board)
            try await storage.move(board.folder, to: destination)
            await scanBoards()
            status = "Restored \(board.display) \(board.currentVersion)."
        } catch {
            status = "Couldn't restore: \(error.localizedDescription)"
        }
    }

    func deleteArchived() async {
        let targets = archivedBoards
        guard !targets.isEmpty else { return }
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        var removed = 0
        for board in targets where (try? await storage.delete(board.folder, recursive: true)) != nil {
            removed += 1
        }
        await scanBoards()
        status = "Deleted \(removed) archived folder\(removed == 1 ? "" : "s")."
    }

    /// Extract `(version, boardKey)` from a Marauder image filename, robust to every
    /// release/local naming variant we've seen:
    ///   esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin   (release: version + date + board)
    ///   esp32_marauder_v1_12_1_v6_1_0x10000.bin               (local: version + board + offset)
    ///   esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin    (local: version + offset + board)
    /// Strips the prefix, the `vN_NN_NN` version, an optional 8-digit build date, and any
    /// `0x…` flash-offset token; whatever remains is the board key (e.g. `esp32c5devkitc1`,
    /// `v6_1`, `marauder_v7`, `cyd_2432S028`).
    nonisolated static func parseImageName(_ name: String) -> (version: String, key: String)? {
        guard name.hasPrefix("esp32_marauder_"), name.hasSuffix(".bin") else { return nil }
        var parts = name.dropFirst("esp32_marauder_".count)
                        .dropLast(".bin".count)
                        .split(separator: "_").map(String.init)
        // Version = first `v<digits>` followed by two all-numeric tokens.
        var version: String?
        for i in parts.indices where i + 2 < parts.count {
            let v = parts[i]
            guard v.hasPrefix("v"), v.count > 1, v.dropFirst().allSatisfy(\.isNumber),
                  parts[i + 1].allSatisfy(\.isNumber), parts[i + 2].allSatisfy(\.isNumber) else { continue }
            version = "\(v).\(parts[i + 1]).\(parts[i + 2])"
            parts.removeSubrange(i...(i + 2))
            break
        }
        guard let version else { return nil }
        // Drop a build date (8 digits) and the flash-offset token(s); keep the board key.
        parts.removeAll { ($0.count == 8 && $0.allSatisfy(\.isNumber)) || $0.hasPrefix("0x") }
        let key = parts.joined(separator: "_")
        guard !key.isEmpty else { return nil }
        return (version, key)
    }

    // MARK: - Scan + check

    func refresh() async {
        transferChannel = storage.channel
        busy = true; defer { busy = false }
        status = "Checking via \(transferChannel.label)…"
        await scanBoards()
        await checkLatest()
        if let t = latestTag {
            status = updateAvailable ? "Update available: \(t)" : "Up to date (\(t))"
        } else {
            status = "Couldn't reach GitHub."
        }
    }

    private func scanBoards() async {
        guard let dirs = try? await storage.list(Self.flasherDir) else {
            boards = []
            archivedBoards = []
            return
        }
        var found: [Board] = []
        for d in dirs where Self.isManualFolder(d.name) {
            if let board = await board(from: d) {
                found.append(board)
            }
        }
        boards = found

        let archiveDirs = (try? await storage.list(Self.archiveDir)) ?? []
        var archived: [Board] = []
        for d in archiveDirs where Self.isManualFolder(d.name) {
            if let board = await board(from: d) {
                archived.append(board)
            }
        }
        archivedBoards = archived.sorted {
            $0.display == $1.display ? Self.isNewer($0.currentVersion, than: $1.currentVersion)
                                     : $0.display < $1.display
        }
    }

    nonisolated static func isManualFolder(_ name: String) -> Bool {
        name.hasSuffix("_manual")
    }

    nonisolated static func folderName(from path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func board(from directory: FlipperFile) async -> Board? {
        guard directory.isDirectory, Self.isManualFolder(directory.name),
              let files = try? await storage.list(directory.path) else { return nil }
        // The app image is the `esp32_marauder_*` .bin (boot files are named
        // bootloader_*/partitions_*/boot_app0_*). Prefer the one at offset 0x10000.
        let marauder = files.filter { $0.name.hasPrefix("esp32_marauder_") && $0.name.hasSuffix(".bin") }
        guard let app = marauder.first(where: { $0.name.contains("0x10000") }) ?? marauder.first,
              let parsed = Self.parseImageName(app.name) else { return nil }
        let boot = files.filter { $0.name.hasSuffix(".bin") && $0.name != app.name }.map(\.name)
        let base = String(directory.name.dropLast("_manual".count))
        return Board(folder: directory.path, base: base, display: Self.cleanBase(base),
                     key: parsed.key, currentVersion: parsed.version,
                     appName: app.name, bootFiles: boot)
    }

    private func uniqueArchivePath(for board: Board) async -> String {
        await uniquePath(directory: Self.archiveDir, folderName: Self.folderName(from: board.folder))
    }

    private func uniqueActivePath(for board: Board) async -> String {
        await uniquePath(directory: Self.flasherDir, folderName: Self.folderName(from: board.folder))
    }

    private func uniquePath(directory: String, folderName: String) async -> String {
        let manualSuffix = "_manual"
        let stem = Self.isManualFolder(folderName)
            ? String(folderName.dropLast(manualSuffix.count))
            : folderName

        var candidate = "\(directory)/\(folderName)"
        var index = 2
        while await storage.exists(candidate) {
            candidate = "\(directory)/\(stem)_arch\(index)\(manualSuffix)"
            index += 1
        }
        return candidate
    }

    private func checkLatest() async {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                latestTag = tag
                latestAssets = [:]; latestAssetSizes = [:]
                for a in (obj["assets"] as? [[String: Any]]) ?? [] {
                    guard let n = a["name"] as? String,
                          let u = a["browser_download_url"] as? String,
                          let url = URL(string: u) else { continue }
                    latestAssets[n] = url
                    latestAssetSizes[n] = (a["size"] as? Int) ?? 0
                }
            }
        } catch { elog.error("github check: \(error.localizedDescription, privacy: .public)") }
    }

    private var latestAssets: [String: URL] = [:]
    private var latestAssetSizes: [String: Int] = [:]

    private func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download + write a new manual folder

    func install(_ board: Board) async {
        guard let tag = latestTag else { return }
        let storage = self.storage
        let channel = storage.channel
        transferChannel = channel
        busy = true; progress = 0; downloadPhase = true; progressText = nil
        defer { busy = false; progress = nil; downloadPhase = false; progressText = nil }

        // Find the release asset whose own parsed board key matches this board — robust
        // to the release naming carrying a build date the local file may not have.
        guard let (assetName, assetURL) = latestAssets.first(where: {
            Self.parseImageName($0.key)?.key == board.key
        }) else {
            status = "No “\(board.key)” board image in \(tag)."; return
        }
        status = "Downloading \(assetName)…"
        // Stream the download so we can show live percent + downloaded/total,
        // falling back to the size GitHub reported when the CDN response omits
        // Content-Length. Progress drives the same bar the write phase reuses.
        let knownTotal = Int64(latestAssetSizes[assetName] ?? 0)
        let appData: Data
        do {
            // didWriteData fires once per network read (tens–hundreds of times for a
            // multi-MB image). Coalesce on the delegate's serial queue to whole-percent
            // steps (or ~256KB steps when the total is unknown) so we don't spawn a
            // main-actor Task + two ByteCountFormatter allocations per read. The captured
            // counters are safe: callbacks for one task are delivered serially.
            var lastPct = -1
            var lastWritten: Int64 = 0
            let delegate = DownloadProgressDelegate { [weak self] written, expected in
                let total = expected > 0 ? expected : knownTotal
                if total > 0 {
                    let fraction = min(1, Double(written) / Double(total))
                    let pct = Int(fraction * 100)
                    if pct == lastPct { return }
                    lastPct = pct
                    Task { @MainActor in
                        guard let self, self.downloadPhase else { return }
                        self.progress = fraction
                        self.progressText = "\(pct)% · \(Self.fileSize(written)) / \(Self.fileSize(total))"
                    }
                } else {
                    if written - lastWritten < 256 * 1024 { return }
                    lastWritten = written
                    Task { @MainActor in
                        guard let self, self.downloadPhase else { return }
                        self.progressText = Self.fileSize(written)
                    }
                }
            }
            let (tmp, _) = try await URLSession.shared.download(from: assetURL, delegate: delegate)
            appData = try Data(contentsOf: tmp)
        } catch { status = "Download failed: \(error.localizedDescription)"; return }
        // Close the download phase (on the main actor, no await before the write phase)
        // so any still-queued progress Task no-ops instead of clobbering the write bar.
        downloadPhase = false
        progress = nil            // hand the bar back to the write phase
        progressText = nil        // write phase re-populates it per percent
        status = "Preparing…"     // neutral caption during the boot-file copy

        // Guard a truncated download against the size GitHub reported.
        let expectedSize = latestAssetSizes[assetName] ?? 0
        if expectedSize > 0 && appData.count != expectedSize {
            status = "Download incomplete (\(appData.count)/\(expectedSize) B). Check your connection and retry."
            return
        }
        let expectedMD5 = md5Hex(appData)

        let newVerUnderscored = tag.replacingOccurrences(of: ".", with: "_")   // "v1_12_2"
        // Use the cleaned base so repeated updates don't stack version suffixes
        // (module_one_v6_1_v1_12_2_v1_12_3_manual …).
        let newFolder = "\(Self.flasherDir)/\(Self.cleanBase(board.base))_\(newVerUnderscored)_manual"
        let appOut = "\(newFolder)/esp32_marauder_\(newVerUnderscored)_\(board.key)_0x10000.bin"

        let transferReporter = TransferActivityReporter(channel: channel)
        _ = await transferReporter.prepare()
        transferReporter.begin("ESP32 \(board.key)")
        defer { transferReporter.end() }

        do {
            try await storage.makeDirectory(newFolder)
            // Reuse the version-independent boot files from the existing folder.
            for name in board.bootFiles {
                let data = try await storage.read("\(board.folder)/\(name)")
                try await storage.write("\(newFolder)/\(name)", data: data)
            }
            // Write the new application image at 0x10000, then VERIFY it landed
            // intact (a dropped BLE link mid-write silently truncates the file and
            // bricks the flash). Retry once; never leave a partial image behind.
            let totalBytes = Int64(appData.count)
            var ok = false
            for attempt in 0..<2 {
                let note = channel == .usb ? "keep USB SD Mode active" : "keep this app open"
                status = attempt == 0
                    ? "Writing via \(channel.label)… \(note)"
                    : "Write incomplete — retrying via \(channel.label)… \(note)"
                progress = 0
                var lastWritePct = -1
                try await storage.write(appOut, data: appData) { [weak self] sent in
                    // Coalesce to whole-percent steps on the callback thread so we don't
                    // spawn a main-actor Task + two ByteCountFormatter allocations per chunk.
                    let pct = Int((Double(sent) / Double(max(1, totalBytes))) * 100)
                    if pct == lastWritePct { return }
                    lastWritePct = pct
                    Task { @MainActor in
                        guard let self else { return }
                        self.progress = min(1, Double(sent) / Double(max(1, totalBytes)))
                        self.progressText = "\(pct)% · \(Self.fileSize(Int64(sent))) / \(Self.fileSize(totalBytes))"
                        transferReporter.progress(assetName)
                    }
                }
                if await storage.md5(appOut) == expectedMD5 { ok = true; break }
            }
            progressText = nil
            if ok {
                status = "Done ✓ verified. Flash \(board.base) \(tag) from the Flipper’s esp_flasher app."
            } else {
                try? await storage.delete(appOut)   // remove the bad image so it can't be flashed
                let devSize = (try? await storage.list(newFolder))?.first { $0.name.hasSuffix("_0x10000.bin") }?.size ?? 0
                status = "Write failed: only \(devSize)/\(appData.count) B landed. Keep the app foregrounded and tap Update again."
            }
            await scanBoards()
        } catch {
            status = "Write failed: \(error.localizedDescription)"
        }
    }

    private static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Bridges `URLSessionDownloadTask` byte-progress callbacks into a closure so the
/// async `download(from:delegate:)` call can drive a live progress bar. The async
/// method still owns completion (the returned temp URL); this delegate only
/// forwards the informational `didWriteData` ticks. Callbacks arrive on the
/// session's delegate queue, so the handler is responsible for hopping to the
/// main actor before touching UI state.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (_ written: Int64, _ expected: Int64) -> Void

    init(_ onProgress: @escaping (_ written: Int64, _ expected: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    // Required by the protocol; the async download(from:delegate:) call consumes
    // completion itself and hands back the temp URL, so nothing to do here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
