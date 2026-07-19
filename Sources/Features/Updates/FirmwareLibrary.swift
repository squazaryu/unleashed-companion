import CryptoKit
import Foundation
import SWCompression

struct FirmwareRelease: Identifiable, Equatable {
    let id: String
    let tag: String
    let title: String
    let version: String
    let channel: TumoflipFirmwareChannel
    let publishedAt: Date
    let notes: String
    let updaterURL: URL
    let updaterSize: Int64
    let updaterSHA256: String?
    let checksumsURL: URL?
    let manifestURL: URL?

    var cacheFileName: String { updaterURL.lastPathComponent }
    var updateDirectoryName: String { "f7-update-\(version)" }

    var versionLine: String {
        let numbers = version.split(whereSeparator: { !$0.isNumber })
        guard numbers.count >= 2 else { return version }
        return "\(numbers[0])-\(numbers[1])"
    }

    var buildLabel: String {
        let numbers = version.split(whereSeparator: { !$0.isNumber })
        guard channel == .dev, numbers.count >= 3 else { return "Release" }
        return "Beta \(numbers[2])"
    }
}

struct FirmwareVersionGroup: Identifiable, Equatable {
    let id: String
    let line: String
    let releases: [FirmwareRelease]
}

enum FirmwareReleaseGrouping {
    static func group(_ releases: [FirmwareRelease]) -> [FirmwareVersionGroup] {
        var order: [String] = []
        var grouped: [String: [FirmwareRelease]] = [:]

        for release in releases {
            let channel = release.channel == .dev ? "dev" : "main"
            let key = "\(channel)-\(release.versionLine)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(release)
        }

        return order.compactMap { key in
            guard let releases = grouped[key], let first = releases.first else { return nil }
            return FirmwareVersionGroup(id: key, line: first.versionLine, releases: releases)
        }
    }
}

enum FirmwareReleasePolicy {
    static func visible(
        _ releases: [FirmwareRelease],
        channel: TumoflipFirmwareChannel,
        limit: Int = 20
    ) -> [FirmwareRelease] {
        let channelReleases = releases.filter { $0.channel == channel }
        guard channel == .dev,
              let latestMainDate = releases.lazy
                  .filter({ $0.channel == .stable })
                  .map(\.publishedAt)
                  .max() else {
            return Array(channelReleases.prefix(limit))
        }

        return Array(
            channelReleases.lazy
                .filter { $0.publishedAt > latestMainDate }
                .prefix(limit)
        )
    }
}

struct FirmwareArchiveFile: Equatable {
    let name: String
    let data: Data
}

enum FirmwareLibraryError: LocalizedError, Equatable {
    case invalidResponse
    case missingChecksum
    case checksumMismatch
    case invalidArchive(String)
    case flipperNotReady
    case alreadyBusy
    case stopped
    case deviceVerifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid firmware catalog response."
        case .missingChecksum: return "This release has no SHA-256 checksum for its updater."
        case .checksumMismatch: return "The downloaded updater failed SHA-256 verification. Nothing was written to the Flipper."
        case .invalidArchive(let reason): return "The updater archive is invalid: \(reason)."
        case .flipperNotReady: return "Connect the Flipper over BLE, or select its SD card over USB."
        case .alreadyBusy: return "Another firmware transfer is already running."
        case .stopped: return "Stopped before the next file. The incomplete update folder was removed."
        case .deviceVerifyFailed(let file): return "On-device verification failed for \(file). The incomplete update folder was removed."
        }
    }
}

enum FirmwareArchive {
    static let requiredFiles = [
        "firmware.dfu", "radio.bin", "resources.ths", "splash.bin", "updater.bin", "update.fuf",
    ]

    static func decode(_ tgz: Data, expectedDirectory: String) throws -> [FirmwareArchiveFile] {
        let tar: Data
        do {
            tar = try GzipArchive.unarchive(archive: tgz)
        } catch {
            throw FirmwareLibraryError.invalidArchive("GZip stream cannot be decoded")
        }

        let entries: [TarEntry]
        do {
            entries = try TarContainer.open(container: tar)
        } catch {
            throw FirmwareLibraryError.invalidArchive("TAR container cannot be decoded")
        }

        var files: [String: Data] = [:]
        for entry in entries {
            guard entry.info.type == .regular else { continue }
            guard let data = entry.data else { continue }
            let components = entry.info.name.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count == 2,
                  components[0] == Substring(expectedDirectory),
                  !components.contains("."), !components.contains("..") else {
                throw FirmwareLibraryError.invalidArchive("unsafe path \(entry.info.name)")
            }
            let name = String(components[1])
            guard requiredFiles.contains(name), files[name] == nil else {
                throw FirmwareLibraryError.invalidArchive("unexpected or duplicate file \(name)")
            }
            files[name] = data
        }

        let missing = requiredFiles.filter { files[$0] == nil }
        guard missing.isEmpty else {
            throw FirmwareLibraryError.invalidArchive("missing \(missing.joined(separator: ", "))")
        }
        return requiredFiles.compactMap { name in files[name].map { FirmwareArchiveFile(name: name, data: $0) } }
    }
}

@MainActor
final class FirmwareLibrary: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case downloading(version: String, fraction: Double?)
        case verifying(version: String)
        case staging(version: String, file: String, doneBytes: Int64, totalBytes: Int64)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var releases: [FirmwareRelease] = []
    @Published private(set) var selectedChannel: TumoflipFirmwareChannel = .stable
    @Published private(set) var installedVersion: String?
    @Published private(set) var installedAPI: String?
    @Published private(set) var transferChannel: TransferChannel = .ble
    @Published private(set) var stopRequested = false

    private let repo = "squazaryu/tumoflip"
    private var loadTask: Task<Void, Never>?
    private var operationRunning = false

    var busy: Bool {
        switch phase {
        case .loading, .downloading, .verifying, .staging: return true
        default: return false
        }
    }

    var visibleReleases: [FirmwareRelease] {
        FirmwareReleasePolicy.visible(releases, channel: selectedChannel)
    }

    var visibleGroups: [FirmwareVersionGroup] {
        FirmwareReleaseGrouping.group(visibleReleases)
    }

    func setChannel(_ channel: TumoflipFirmwareChannel) {
        selectedChannel = channel
    }

    func loadIfNeeded() {
        guard releases.isEmpty, loadTask == nil else { return }
        refresh()
    }

    func refresh() {
        guard loadTask == nil else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadCatalog()
            self.loadTask = nil
        }
    }

    func requestStop() { stopRequested = true }

    func stage(_ release: FirmwareRelease) async {
        guard !operationRunning else {
            phase = .failed(FirmwareLibraryError.alreadyBusy.localizedDescription)
            return
        }
        operationRunning = true
        stopRequested = false
        defer { operationRunning = false }

        let store = TransferChannelStore.shared.activeStore
        transferChannel = store.channel
        if store.channel == .ble,
           await FlipperBLE.shared.waitUntilReady(timeout: 10) == false {
            phase = .failed(FirmwareLibraryError.flipperNotReady.localizedDescription)
            return
        }

        let remoteRoot = "/ext/update/\(release.updateDirectoryName)"
        let activity = InstallActivityController()
        let reporter = TransferActivityReporter(channel: store.channel)
        do {
            let archiveData = try await cachedArchive(for: release)
            phase = .verifying(version: release.version)
            let expected = try await expectedSHA256(for: release)
            guard Self.sha256(archiveData) == expected else {
                throw FirmwareLibraryError.checksumMismatch
            }
            let files = try FirmwareArchive.decode(
                archiveData, expectedDirectory: release.updateDirectoryName)
            let ordered = files.filter { $0.name != "update.fuf" } + files.filter { $0.name == "update.fuf" }
            let total = Int64(ordered.reduce(0) { $0 + $1.data.count })
            var completed: Int64 = 0

            try? await store.delete(remoteRoot, recursive: true)
            try await store.makeDirectory("/ext/update")
            try await store.makeDirectory(remoteRoot)
            activity.start(total: ordered.count, title: "Staging Tumoflip firmware")
            _ = await reporter.prepare()
            reporter.begin("firmware \(release.version)")
            defer { reporter.end() }

            for (index, file) in ordered.enumerated() {
                if stopRequested { throw FirmwareLibraryError.stopped }
                let finalPath = "\(remoteRoot)/\(file.name)"
                let tempPath = "\(finalPath).part"
                phase = .staging(
                    version: release.version, file: file.name,
                    doneBytes: completed, totalBytes: total)
                activity.update(current: index + 1, total: ordered.count, name: file.name)
                reporter.progress(file.name, force: true)
                let base = completed
                try await stageFile(
                    file, tempPath: tempPath, finalPath: finalPath,
                    store: store, release: release, base: base, total: total)
                completed += Int64(file.data.count)
            }

            activity.finish(installed: ordered.count, total: ordered.count)
            phase = .done("\(release.version) is ready in Archive > update.")
        } catch {
            try? await store.delete(remoteRoot, recursive: true)
            activity.cancel()
            if UpdateTaskCancellation.isCancellation(error) {
                phase = .ready
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func stageFile(
        _ file: FirmwareArchiveFile,
        tempPath: String,
        finalPath: String,
        store: any DeviceFileStore,
        release: FirmwareRelease,
        base: Int64,
        total: Int64
    ) async throws {
        let attempts = store.channel == .ble ? 3 : 1
        var lastError: Error = FirmwareLibraryError.deviceVerifyFailed(file.name)

        for attempt in 1...attempts {
            do {
                if store.channel == .ble,
                   await FlipperBLE.shared.waitUntilReady(timeout: attempt == 1 ? 6 : 15) == false {
                    throw FirmwareLibraryError.flipperNotReady
                }
                try? await store.delete(tempPath, recursive: false)
                try await store.write(tempPath, data: file.data) { [weak self] sent in
                    Task { @MainActor in
                        guard let self else { return }
                        self.phase = .staging(
                            version: release.version, file: file.name,
                            doneBytes: base + Int64(sent), totalBytes: total)
                    }
                }
                guard await store.md5(tempPath) == Self.md5(file.data) else {
                    throw FirmwareLibraryError.deviceVerifyFailed(file.name)
                }
                try? await store.delete(finalPath, recursive: false)
                try await store.move(tempPath, to: finalPath)
                return
            } catch {
                lastError = error
                try? await store.delete(tempPath, recursive: false)
                guard attempt < attempts, !stopRequested else { break }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        if stopRequested { throw FirmwareLibraryError.stopped }
        throw lastError
    }

    private func loadCatalog() async {
        let prior = releases
        phase = .loading
        do {
            await refreshInstalledIdentity()
            var components = URLComponents(string: "https://api.github.com/repos/\(repo)/releases")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw FirmwareLibraryError.invalidResponse
            }
            releases = try FirmwareCatalog.decode(data)
            phase = .ready
        } catch {
            if UpdateTaskCancellation.isCancellation(error) {
                releases = prior
                phase = prior.isEmpty ? .idle : .ready
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func refreshInstalledIdentity() async {
        guard FlipperBLE.shared.state == .ready,
              let info = try? await FlipperSystem().deviceInfo() else { return }
        let identity = TumoflipDeviceIdentity(deviceInfo: info)
        installedVersion = identity.firmwareVersion
        installedAPI = identity.firmwareAPI
        if let channel = identity.inferredChannel { selectedChannel = channel }
    }

    private func cachedArchive(for release: FirmwareRelease) async throws -> Data {
        let directory = try Self.cacheDirectory(for: release)
        let file = directory.appendingPathComponent(release.cacheFileName)
        if let data = try? Data(contentsOf: file),
           let expected = try? await expectedSHA256(for: release),
           Self.sha256(data) == expected {
            return data
        }

        phase = .downloading(version: release.version, fraction: 0)
        var lastPercent = -1
        let delegate = FirmwareDownloadProgressDelegate { [weak self] written, expected in
            guard expected > 0 else { return }
            let fraction = min(1, Double(written) / Double(expected))
            let percent = Int(fraction * 100)
            guard percent != lastPercent else { return }
            lastPercent = percent
            Task { @MainActor in
                self?.phase = .downloading(version: release.version, fraction: fraction)
            }
        }
        let (temporary, _) = try await URLSession.shared.download(from: release.updaterURL, delegate: delegate)
        let data = try Data(contentsOf: temporary)
        guard release.updaterSize <= 0 || Int64(data.count) == release.updaterSize else {
            throw FirmwareLibraryError.invalidResponse
        }
        let expected = try await expectedSHA256(for: release)
        guard Self.sha256(data) == expected else { throw FirmwareLibraryError.checksumMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }

    private func expectedSHA256(for release: FirmwareRelease) async throws -> String {
        if let digest = release.updaterSHA256 { return digest }
        guard let url = release.checksumsURL else { throw FirmwareLibraryError.missingChecksum }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw FirmwareLibraryError.missingChecksum
        }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2,
               String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == release.cacheFileName {
                let digest = String(parts[0]).lowercased()
                if digest.count == 64 { return digest }
            }
        }
        throw FirmwareLibraryError.missingChecksum
    }

    private static func cacheDirectory(for release: FirmwareRelease) throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let safeTag = release.tag.replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("FirmwareLibrary", isDirectory: true)
            .appendingPathComponent(safeTag, isDirectory: true)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum FirmwareCatalog {
    static func decode(_ data: Data) throws -> [FirmwareRelease] {
        let sorted = try JSONDecoder.github.decode([GitHubRelease].self, from: data)
            .compactMap(mapRelease)
            .sorted { $0.publishedAt > $1.publishedAt }
        var versions = Set<String>()
        return sorted.filter { versions.insert($0.version).inserted }
    }

    private static func mapRelease(_ release: GitHubRelease) -> FirmwareRelease? {
        guard !release.draft,
              let publishedAt = release.publishedAt,
              let updater = release.assets.first(where: {
                  $0.name.hasPrefix("flipper-z-f7-update-") && $0.name.hasSuffix(".tgz")
              }) else { return nil }
        let version = updater.name
            .replacingOccurrences(of: "flipper-z-f7-update-", with: "")
            .replacingOccurrences(of: ".tgz", with: "")
        guard let channel = TumoflipFirmwareChannel.infer(version: version),
              (channel == .dev) == release.prerelease else { return nil }
        let digest = updater.digest.flatMap { value -> String? in
            guard value.hasPrefix("sha256:") else { return nil }
            return String(value.dropFirst("sha256:".count)).lowercased()
        }
        let checksums = release.assets.first { $0.name.hasSuffix("SHA256SUMS") }
        let manifest = release.assets.first { $0.name == "tumoflip-packages.json" }
        let title = release.name.flatMap { $0.isEmpty ? nil : $0 } ?? release.tagName
        return FirmwareRelease(
            id: release.tagName, tag: release.tagName, title: title,
            version: version, channel: channel, publishedAt: publishedAt,
            notes: release.body ?? "", updaterURL: updater.downloadURL,
            updaterSize: updater.size, updaterSHA256: digest,
            checksumsURL: checksums?.downloadURL, manifestURL: manifest?.downloadURL)
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL
        let size: Int64
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case downloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let publishedAt: Date?
    let prerelease: Bool
    let draft: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, prerelease, draft, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
    }
}

private extension JSONDecoder {
    static var github: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class FirmwareDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (_ written: Int64, _ expected: Int64) -> Void

    init(_ onProgress: @escaping (_ written: Int64, _ expected: Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
