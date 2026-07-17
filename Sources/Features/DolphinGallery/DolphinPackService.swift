import CryptoKit
import Foundation
import ZIPFoundation

enum DolphinLibrarySource: String, CaseIterable, Codable, Identifiable {
    case legacy = "Legacy"
    case momentum = "Momentum"
    case talkingSasquach = "Talking Sasquach"
    case kuronons = "Kuronons"
    case haseo = "Haseo"
    case stopOxy = "stop oxy"
    case wr3nch = "WR3NCH"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .legacy: return "archivebox"
        case .momentum: return "bolt.horizontal.circle"
        case .talkingSasquach: return "person.wave.2"
        case .kuronons: return "paintpalette"
        case .haseo: return "film.stack"
        case .stopOxy: return "sparkles.tv"
        case .wr3nch: return "wrench.and.screwdriver"
        }
    }
}

struct DolphinRemoteFile: Hashable, Codable {
    let name: String
    let sha256: String
}

struct DolphinPackDescriptor: Identifiable, Hashable {
    enum Payload: Hashable {
        case bundled(resourcePath: String)
        case remoteZip(url: URL, sha256: String)
        case remoteFiles(baseURL: URL, files: [DolphinRemoteFile])
        case repositoryArchive(
            url: URL,
            sha256: String,
            rootDirectory: String,
            animationPath: String
        )
    }

    let id: String
    let title: String
    let source: DolphinLibrarySource
    let author: String
    let sourceURL: URL
    let previewURL: URL?
    let payload: Payload

    var animation: DolphinAnimation {
        DolphinAnimation(id: id, source: source, previewURL: previewURL)
    }

    var cacheFingerprint: String {
        let identity: String
        switch payload {
        case .bundled(let resourcePath):
            identity = "bundled:\(resourcePath)"
        case .remoteZip(let url, let sha256):
            identity = "zip:\(url.absoluteString):\(sha256.lowercased())"
        case .remoteFiles(let baseURL, let files):
            let fileIdentity = files
                .sorted { $0.name < $1.name }
                .map { "\($0.name):\($0.sha256.lowercased())" }
                .joined(separator: ",")
            identity = "files:\(baseURL.absoluteString):\(fileIdentity)"
        case .repositoryArchive(let url, let sha256, let rootDirectory, let animationPath):
            identity = "repo:\(url.absoluteString):\(sha256.lowercased()):\(rootDirectory):\(animationPath)"
        }
        return TumoflipHash.sha256(Data(identity.utf8))
    }
}

enum DolphinPackCatalog {
    static let momentumRepository = URL(string: "https://github.com/Next-Flip/Momentum-Firmware")!

    static let momentum: [DolphinPackDescriptor] = [
        DolphinPackDescriptor(
            id: "L1_3d_printing_128x64",
            title: "3D Printing",
            source: .momentum,
            author: "Momentum Firmware contributors",
            sourceURL: momentumRepository,
            previewURL: rawURL(
                "https://raw.githubusercontent.com/Next-Flip/Momentum-Firmware/dev/assets/dolphin/external/L1_3d_printing_128x64/frame_0.png"
            ),
            payload: .bundled(resourcePath: "Momentum/L1_3d_printing_128x64")
        ),
        DolphinPackDescriptor(
            id: "L1_Wardriving_128x64",
            title: "Wardriving",
            source: .momentum,
            author: "Momentum Firmware contributors",
            sourceURL: momentumRepository,
            previewURL: rawURL(
                "https://raw.githubusercontent.com/Next-Flip/Momentum-Firmware/dev/assets/dolphin/external/L1_Wardriving_128x64/frame_0.png"
            ),
            payload: .bundled(resourcePath: "Momentum/L1_Wardriving_128x64")
        ),
    ]

    static let remote: [DolphinPackDescriptor] = loadRemoteCatalog()
    static let installable = momentum + remote

    static let talkingSasquach = packs(for: .talkingSasquach)
    static let kuronons = packs(for: .kuronons)
    static let haseo = packs(for: .haseo)
    static let stopOxy = packs(for: .stopOxy)
    static let wr3nch = packs(for: .wr3nch)

    static func packs(for source: DolphinLibrarySource) -> [DolphinPackDescriptor] {
        switch source {
        case .legacy:
            return []
        case .momentum:
            return momentum
        default:
            return remote.filter { $0.source == source }
        }
    }

    static func repository(for source: DolphinLibrarySource) -> URL? {
        if source == .momentum { return momentumRepository }
        return packs(for: source).first?.sourceURL
    }

    private struct CatalogDocument: Decodable {
        let version: Int
        let packs: [CatalogPack]
    }

    private struct CatalogPack: Decodable {
        let id: String
        let title: String
        let source: DolphinLibrarySource
        let author: String
        let sourceURL: URL
        let previewURL: URL?
        let payload: CatalogPayload

        var descriptor: DolphinPackDescriptor {
            DolphinPackDescriptor(
                id: id,
                title: title,
                source: source,
                author: author,
                sourceURL: sourceURL,
                previewURL: previewURL,
                payload: payload.descriptorPayload
            )
        }
    }

    private struct CatalogPayload: Decodable {
        enum Kind: String, Decodable {
            case remoteZip
            case remoteFiles
            case repositoryArchive
        }

        let kind: Kind
        let url: URL?
        let sha256: String?
        let baseURL: URL?
        let files: [DolphinRemoteFile]?
        let rootDirectory: String?
        let animationPath: String?

        var descriptorPayload: DolphinPackDescriptor.Payload {
            switch kind {
            case .remoteZip:
                guard let url, let sha256 else { preconditionFailure("Invalid remote ZIP catalog entry") }
                return .remoteZip(url: url, sha256: sha256)
            case .remoteFiles:
                guard let baseURL, let files, !files.isEmpty else {
                    preconditionFailure("Invalid remote file catalog entry")
                }
                return .remoteFiles(baseURL: baseURL, files: files)
            case .repositoryArchive:
                guard let url, let sha256, let rootDirectory, let animationPath else {
                    preconditionFailure("Invalid repository archive catalog entry")
                }
                return .repositoryArchive(
                    url: url,
                    sha256: sha256,
                    rootDirectory: rootDirectory,
                    animationPath: animationPath
                )
            }
        }
    }

    private static func loadRemoteCatalog(bundle: Bundle = .main) -> [DolphinPackDescriptor] {
        guard let url = bundle.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "DolphinPacks"
        ), let data = try? Data(contentsOf: url),
        let document = try? JSONDecoder().decode(CatalogDocument.self, from: data),
        document.version == 1 else {
            preconditionFailure("Missing or invalid Dolphin pack catalog")
        }
        return document.packs.map(\.descriptor)
    }

    private static func rawURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid bundled catalog URL: \(value)")
        }
        return url
    }
}

struct DolphinPackPayload: Equatable {
    let animationID: String
    let files: [String: Data]
}

enum DolphinPackSyncStage: String, Sendable {
    case caching
    case uploading
    case removing
    case profile
}

struct DolphinPackSyncProgress: Equatable, Sendable {
    let stage: DolphinPackSyncStage
    let completed: Int
    let total: Int
    let item: String?
}

enum DolphinPackError: LocalizedError, Equatable {
    case downloadFailed
    case archiveTooLarge
    case digestMismatch
    case invalidArchive
    case unsafePath
    case invalidMetadata
    case missingFrames
    case bundledResourceMissing
    case stagedFileMismatch(String)
    case invalidManifest

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "The animation could not be downloaded from its source."
        case .archiveTooLarge:
            return "The animation archive exceeds the safe size limit."
        case .digestMismatch:
            return "The downloaded animation does not match the reviewed source."
        case .invalidArchive:
            return "The animation archive has an unsupported structure."
        case .unsafePath:
            return "The animation archive contains an unsafe path."
        case .invalidMetadata:
            return "The animation metadata is invalid or unsupported."
        case .missingFrames:
            return "The animation archive is missing one or more frames."
        case .bundledResourceMissing:
            return "The bundled animation resources are missing."
        case .stagedFileMismatch(let file):
            return "The Flipper could not verify \(file)."
        case .invalidManifest:
            return "The Flipper animation manifest is invalid."
        }
    }
}

enum DolphinPackArchive {
    static let maximumArchiveBytes = 2 * 1_024 * 1_024
    static let maximumRepositoryArchiveBytes = 8 * 1_024 * 1_024
    static let maximumExtractedBytes = 2 * 1_024 * 1_024
    static let maximumEntries = 512
    static let maximumRepositoryEntries = 10_000
    static let maximumFrames = 256

    static func decode(
        _ data: Data,
        descriptor: DolphinPackDescriptor,
        expectedSHA256: String
    ) throws -> DolphinPackPayload {
        guard data.count <= maximumArchiveBytes else { throw DolphinPackError.archiveTooLarge }
        guard sha256(data) == expectedSHA256.lowercased() else {
            throw DolphinPackError.digestMismatch
        }
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DolphinPackError.invalidArchive
        }

        var files: [String: Data] = [:]
        var totalBytes = 0
        var entryCount = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumEntries else { throw DolphinPackError.invalidArchive }
            let components = try safeComponents(entry.path)
            guard components.first == descriptor.id else { throw DolphinPackError.invalidArchive }
            if entry.type == .directory { continue }
            guard entry.type == .file, components.count == 2 else {
                throw DolphinPackError.invalidArchive
            }

            let filename = components[1]
            guard filename == "meta.txt" || isFrameFilename(filename) else {
                throw DolphinPackError.invalidArchive
            }
            guard files[filename] == nil else { throw DolphinPackError.invalidArchive }
            guard Int64(entry.uncompressedSize) <= Int64(maximumExtractedBytes - totalBytes) else {
                throw DolphinPackError.archiveTooLarge
            }

            var bytes = Data()
            _ = try archive.extract(entry) { chunk in
                bytes.append(chunk)
            }
            totalBytes += bytes.count
            guard totalBytes <= maximumExtractedBytes else {
                throw DolphinPackError.archiveTooLarge
            }
            files[filename] = bytes
        }

        return try validate(animationID: descriptor.id, files: files)
    }

    static func decodeRepositoryArchive(
        _ data: Data,
        descriptor: DolphinPackDescriptor,
        expectedSHA256: String,
        rootDirectory: String,
        animationPath: String
    ) throws -> DolphinPackPayload {
        guard data.count <= maximumRepositoryArchiveBytes else {
            throw DolphinPackError.archiveTooLarge
        }
        guard matchesDigest(data, expectedSHA256: expectedSHA256) else {
            throw DolphinPackError.digestMismatch
        }

        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DolphinPackError.invalidArchive
        }

        let expectedPrefix = try safeComponents(rootDirectory) + safeComponents(animationPath)
        var files: [String: Data] = [:]
        var totalBytes = 0
        var entryCount = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= maximumRepositoryEntries else {
                throw DolphinPackError.invalidArchive
            }
            let components = try safeComponents(entry.path)
            guard components.starts(with: expectedPrefix) else { continue }
            let relative = components.dropFirst(expectedPrefix.count)
            if entry.type == .directory { continue }
            guard entry.type == .file, relative.count == 1,
                  let filename = relative.first,
                  isAllowedPackFilename(filename) else { continue }
            guard files[filename] == nil else { throw DolphinPackError.invalidArchive }
            guard Int64(entry.uncompressedSize) <= Int64(maximumExtractedBytes - totalBytes) else {
                throw DolphinPackError.archiveTooLarge
            }

            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            totalBytes += bytes.count
            guard totalBytes <= maximumExtractedBytes else {
                throw DolphinPackError.archiveTooLarge
            }
            files[filename] = bytes
        }

        return try validate(animationID: descriptor.id, files: files)
    }

    static func loadBundled(
        descriptor: DolphinPackDescriptor,
        bundle: Bundle = .main
    ) throws -> DolphinPackPayload {
        guard case .bundled(let resourcePath) = descriptor.payload,
              let root = bundle.resourceURL?.appendingPathComponent("DolphinPacks/\(resourcePath)"),
              FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            throw DolphinPackError.bundledResourceMissing
        }

        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard url.deletingLastPathComponent() == root else {
                throw DolphinPackError.invalidArchive
            }
            let filename = url.lastPathComponent
            guard filename == "meta.txt" || isFrameFilename(filename) else {
                throw DolphinPackError.invalidArchive
            }
            files[filename] = try Data(contentsOf: url)
        }
        return try validate(animationID: descriptor.id, files: files)
    }

    static func validate(animationID: String, files: [String: Data]) throws -> DolphinPackPayload {
        guard let metadata = files["meta.txt"] else { throw DolphinPackError.invalidMetadata }
        let referencedFrameIndexes = try validateMetadata(metadata)
        let frameIndexes = Set(files.keys.compactMap(frameIndex))
        guard let maximumReferencedFrame = referencedFrameIndexes.max() else {
            throw DolphinPackError.invalidMetadata
        }
        let requiredFrameIndexes = Set(0...maximumReferencedFrame)
        guard !frameIndexes.isEmpty,
              frameIndexes.count <= maximumFrames,
              frameIndexes == requiredFrameIndexes else {
            throw DolphinPackError.missingFrames
        }
        return DolphinPackPayload(animationID: animationID, files: files)
    }

    static func matchesDigest(_ data: Data, expectedSHA256: String) -> Bool {
        sha256(data) == expectedSHA256.lowercased()
    }

    static func isAllowedPackFilename(_ value: String) -> Bool {
        value == "meta.txt" || isFrameFilename(value)
    }

    private static func validateMetadata(_ data: Data) throws -> Set<Int> {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DolphinPackError.invalidMetadata
        }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            values[key] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }

        guard values["Filetype"] == "Flipper Animation",
              values["Version"] == "1",
              let width = values["Width"].flatMap(Int.init),
              let height = values["Height"].flatMap(Int.init),
              (1...128).contains(width),
              (1...64).contains(height),
              let passiveFrames = values["Passive frames"].flatMap(Int.init),
              let activeFrames = values["Active frames"].flatMap(Int.init),
              let frameOrder = values["Frames order"] else {
            throw DolphinPackError.invalidMetadata
        }

        let frameCount = passiveFrames + activeFrames
        let frameIndexes = frameOrder.split(separator: " ").compactMap { Int($0) }
        guard (1...maximumFrames).contains(frameCount),
              frameIndexes.count == frameCount,
              frameIndexes.allSatisfy({ (0..<maximumFrames).contains($0) }) else {
            throw DolphinPackError.invalidMetadata
        }
        return Set(frameIndexes)
    }

    private static func safeComponents(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.contains("\\") else {
            throw DolphinPackError.unsafePath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(".."), !components.contains("."),
              components.filter({ !$0.isEmpty }).count >= 1 else {
            throw DolphinPackError.unsafePath
        }
        return components.filter { !$0.isEmpty }
    }

    private static func isFrameFilename(_ value: String) -> Bool {
        frameIndex(value) != nil
    }

    private static func frameIndex(_ value: String) -> Int? {
        guard value.hasPrefix("frame_"), value.hasSuffix(".bm") else { return nil }
        return Int(value.dropFirst(6).dropLast(3))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor DolphinPackInstaller {
    static let dolphinRoot = "/ext/dolphin"
    static let stockManifestPath = "\(dolphinRoot)/manifest.txt"
    static let manifestPath = "\(DolphinProfileService.directory)/animation_packs.txt"
    static let stagingRoot = "\(dolphinRoot)/.tumocompanion-stage"
    static let backupRoot = "\(DolphinProfileService.directory)/dolphin-pack-backup"
    static let cacheMarker = ".source.sha256"

    let storage: any TumoflipDeviceFS
    let bundle: Bundle
    let session: URLSession
    let cacheRoot: URL
    private let payloadProvider: ((DolphinPackDescriptor) async throws -> DolphinPackPayload)?

    init(
        storage: any TumoflipDeviceFS = FlipperDeviceFS(),
        bundle: Bundle = .main,
        session: URLSession = .shared,
        cacheRoot: URL? = nil,
        payloadProvider: ((DolphinPackDescriptor) async throws -> DolphinPackPayload)? = nil
    ) {
        self.storage = storage
        self.bundle = bundle
        self.session = session
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("TumoCompanion/DolphinPacks", isDirectory: true)
        self.payloadProvider = payloadProvider
    }

    func isCached(_ descriptor: DolphinPackDescriptor) -> Bool {
        (try? cachedPayload(descriptor)) != nil
    }

    func cachedIDs(in descriptors: [DolphinPackDescriptor]) -> Set<String> {
        Set(descriptors.filter(isCached).map(\.id))
    }

    func cache(_ descriptor: DolphinPackDescriptor) async throws {
        _ = try await payload(for: descriptor)
    }

    func isInstalled(_ descriptor: DolphinPackDescriptor) async -> Bool {
        guard await storage.exists("\(Self.dolphinRoot)/\(descriptor.id)/meta.txt") else {
            return false
        }
        let custom = await storage.read(Self.manifestPath)
        let stock = await storage.read(Self.stockManifestPath)
        return [custom, stock].compactMap { $0 }.contains {
            DolphinAnimationManifest.contains(descriptor.id, in: $0)
        }
    }

    func installedIDs() async -> Set<String> {
        let custom = await storage.read(Self.manifestPath)
        let stock = await storage.read(Self.stockManifestPath)
        return [custom, stock].compactMap { $0 }.reduce(into: Set<String>()) {
            $0.formUnion(DolphinAnimationManifest.animationIDs(in: $1))
        }
    }

    func synchronize(
        _ descriptors: [DolphinPackDescriptor],
        progress: @escaping @Sendable (DolphinPackSyncProgress) async -> Void = { _ in }
    ) async throws {
        let ordered = descriptors.sorted { $0.id < $1.id }
        await progress(DolphinPackSyncProgress(
            stage: .caching,
            completed: 0,
            total: ordered.count,
            item: ordered.first?.title
        ))
        for (index, descriptor) in ordered.enumerated() {
            _ = try await payload(for: descriptor)
            await progress(DolphinPackSyncProgress(
                stage: .caching,
                completed: index + 1,
                total: ordered.count,
                item: index + 1 < ordered.count ? ordered[index + 1].title : nil
            ))
        }

        let desiredIDs = ordered.map(\.id)
        let currentManifest = await storage.read(Self.manifestPath) ?? DolphinAnimationManifest.empty
        let currentIDs = DolphinAnimationManifest.animationIDs(in: currentManifest)
        let managedCatalogIDs = Set(DolphinPackCatalog.installable.map(\.id))
        let staleIDs = currentIDs
            .intersection(managedCatalogIDs)
            .subtracting(Set(desiredIDs))
        var newlyInstalledIDs: [String] = []
        var manifestReplaced = false

        do {
            var missing: [DolphinPackDescriptor] = []
            for descriptor in ordered {
                let metadataPath = "\(Self.dolphinRoot)/\(descriptor.id)/meta.txt"
                if !(await storage.exists(metadataPath)) {
                    missing.append(descriptor)
                }
            }
            await progress(DolphinPackSyncProgress(
                stage: .uploading,
                completed: 0,
                total: missing.count,
                item: missing.first?.title
            ))
            for (index, descriptor) in missing.enumerated() {
                try await installDirectory(descriptor)
                newlyInstalledIDs.append(descriptor.id)
                await progress(DolphinPackSyncProgress(
                    stage: .uploading,
                    completed: index + 1,
                    total: missing.count,
                    item: index + 1 < missing.count ? missing[index + 1].title : nil
                ))
            }

            let manifest = try DolphinAnimationManifest.replacing(with: desiredIDs)
            try await replaceManifest(with: manifest)
            manifestReplaced = true

            let catalogTitles = Dictionary(
                uniqueKeysWithValues: DolphinPackCatalog.installable.map { ($0.id, $0.title) }
            )
            let stale = staleIDs.sorted().map { ($0, catalogTitles[$0] ?? $0) }
            await progress(DolphinPackSyncProgress(
                stage: .removing,
                completed: 0,
                total: stale.count,
                item: stale.first?.1
            ))
            for (index, entry) in stale.enumerated() {
                let id = entry.0
                let path = "\(Self.dolphinRoot)/\(id)"
                if await storage.exists(path) {
                    try await storage.deleteTree(path)
                }
                await progress(DolphinPackSyncProgress(
                    stage: .removing,
                    completed: index + 1,
                    total: stale.count,
                    item: index + 1 < stale.count ? stale[index + 1].1 : nil
                ))
            }
            try await storage.write(Data("reload\n".utf8), to: DolphinProfileService.reloadPath)
        } catch {
            if !manifestReplaced {
                for id in newlyInstalledIDs {
                    let path = "\(Self.dolphinRoot)/\(id)"
                    if await storage.exists(path) {
                        try? await storage.deleteTree(path)
                    }
                }
            }
            throw error
        }
    }

    func resetToOriginal(
        progress: @escaping @Sendable (DolphinPackSyncProgress) async -> Void = { _ in }
    ) async throws {
        let manifest = await storage.read(Self.manifestPath)
        let managedCatalogIDs = Set(DolphinPackCatalog.installable.map(\.id))
        let managedIDs = manifest
            .map { DolphinAnimationManifest.animationIDs(in: $0) }
            .map { $0.intersection(managedCatalogIDs) } ?? []
        let catalogTitles = Dictionary(
            uniqueKeysWithValues: DolphinPackCatalog.installable.map { ($0.id, $0.title) }
        )
        let ordered = managedIDs.sorted().map { ($0, catalogTitles[$0] ?? $0) }

        if await storage.exists(Self.manifestPath) {
            try await storage.delete(Self.manifestPath)
        }
        await progress(DolphinPackSyncProgress(
            stage: .removing,
            completed: 0,
            total: ordered.count,
            item: ordered.first?.1
        ))
        for (index, entry) in ordered.enumerated() {
            let id = entry.0
            let path = "\(Self.dolphinRoot)/\(id)"
            if await storage.exists(path) {
                try await storage.deleteTree(path)
            }
            await progress(DolphinPackSyncProgress(
                stage: .removing,
                completed: index + 1,
                total: ordered.count,
                item: index + 1 < ordered.count ? ordered[index + 1].1 : nil
            ))
        }
        try await storage.write(Data("reload\n".utf8), to: DolphinProfileService.reloadPath)
    }

    func install(_ descriptor: DolphinPackDescriptor) async throws {
        let payload = try await payload(for: descriptor)
        let stagedDirectory = "\(Self.stagingRoot)/\(descriptor.id)"
        let finalDirectory = "\(Self.dolphinRoot)/\(descriptor.id)"
        let backupDirectory = "\(Self.backupRoot)/\(descriptor.id)"
        let stagedManifest = "\(Self.backupRoot)/manifest.txt.new"
        let backupManifest = "\(Self.backupRoot)/manifest.txt.previous"

        try await storage.makeDirectory(Self.stagingRoot)
        try await storage.makeDirectory(DolphinProfileService.directory)
        try await storage.makeDirectory(Self.backupRoot)
        if await storage.exists(stagedDirectory) {
            try await storage.deleteTree(stagedDirectory)
        }
        try await storage.makeDirectory(stagedDirectory)

        do {
            for filename in payload.files.keys.sorted() {
                guard let data = payload.files[filename] else { continue }
                let path = "\(stagedDirectory)/\(filename)"
                try await storage.write(data, to: path)
                guard await verify(data, at: path) else {
                    throw DolphinPackError.stagedFileMismatch(filename)
                }
            }

            let currentManifest = await storage.read(Self.manifestPath) ?? DolphinAnimationManifest.empty
            let updatedManifest = try DolphinAnimationManifest.appending(descriptor.id, to: currentManifest)
            if await storage.exists(stagedManifest) {
                try await storage.delete(stagedManifest)
            }
            try await storage.write(updatedManifest, to: stagedManifest)
            guard await storage.read(stagedManifest) == updatedManifest else {
                throw DolphinPackError.stagedFileMismatch("manifest.txt")
            }

            var backedUpDirectory = false
            var backedUpManifest = false
            var activatedDirectory = false
            var activatedManifest = false
            do {
                if await storage.exists(backupDirectory) {
                    try await storage.deleteTree(backupDirectory)
                }
                if await storage.exists(backupManifest) {
                    try await storage.delete(backupManifest)
                }
                if await storage.exists(finalDirectory) {
                    try await storage.move(finalDirectory, to: backupDirectory)
                    backedUpDirectory = true
                }
                if await storage.exists(Self.manifestPath) {
                    try await storage.move(Self.manifestPath, to: backupManifest)
                    backedUpManifest = true
                }
                try await storage.move(stagedDirectory, to: finalDirectory)
                activatedDirectory = true
                try await storage.move(stagedManifest, to: Self.manifestPath)
                activatedManifest = true
                try await storage.write(Data("reload\n".utf8), to: DolphinProfileService.reloadPath)
                if await storage.exists(backupDirectory) {
                    try? await storage.deleteTree(backupDirectory)
                }
                if await storage.exists(backupManifest) {
                    try? await storage.delete(backupManifest)
                }
            } catch {
                if activatedManifest, await storage.exists(Self.manifestPath) {
                    try? await storage.delete(Self.manifestPath)
                }
                if backedUpManifest, await storage.exists(backupManifest) {
                    try? await storage.move(backupManifest, to: Self.manifestPath)
                }
                if activatedDirectory, await storage.exists(finalDirectory) {
                    try? await storage.deleteTree(finalDirectory)
                }
                if backedUpDirectory, await storage.exists(backupDirectory) {
                    try? await storage.move(backupDirectory, to: finalDirectory)
                }
                throw error
            }
        } catch {
            if await storage.exists(stagedDirectory) {
                try? await storage.deleteTree(stagedDirectory)
            }
            if await storage.exists(stagedManifest) {
                try? await storage.delete(stagedManifest)
            }
            throw error
        }
    }

    private func installDirectory(_ descriptor: DolphinPackDescriptor) async throws {
        let payload = try await payload(for: descriptor)
        let stagedDirectory = "\(Self.stagingRoot)/\(descriptor.id)"
        let finalDirectory = "\(Self.dolphinRoot)/\(descriptor.id)"
        let backupDirectory = "\(Self.backupRoot)/\(descriptor.id).sync"

        try await storage.makeDirectory(Self.stagingRoot)
        try await storage.makeDirectory(Self.backupRoot)
        if await storage.exists(stagedDirectory) {
            try await storage.deleteTree(stagedDirectory)
        }
        if await storage.exists(backupDirectory) {
            try await storage.deleteTree(backupDirectory)
        }
        try await storage.makeDirectory(stagedDirectory)

        do {
            for filename in payload.files.keys.sorted() {
                guard let data = payload.files[filename] else { continue }
                let path = "\(stagedDirectory)/\(filename)"
                try await storage.write(data, to: path)
                guard await verify(data, at: path) else {
                    throw DolphinPackError.stagedFileMismatch(filename)
                }
            }

            var backedUp = false
            do {
                if await storage.exists(finalDirectory) {
                    try await storage.move(finalDirectory, to: backupDirectory)
                    backedUp = true
                }
                try await storage.move(stagedDirectory, to: finalDirectory)
                if backedUp, await storage.exists(backupDirectory) {
                    try? await storage.deleteTree(backupDirectory)
                }
            } catch {
                if backedUp, await storage.exists(backupDirectory) {
                    try? await storage.move(backupDirectory, to: finalDirectory)
                }
                throw error
            }
        } catch {
            if await storage.exists(stagedDirectory) {
                try? await storage.deleteTree(stagedDirectory)
            }
            throw error
        }
    }

    private func replaceManifest(with data: Data) async throws {
        let stagedManifest = "\(Self.backupRoot)/manifest.txt.sync"
        let backupManifest = "\(Self.backupRoot)/manifest.txt.sync.previous"
        try await storage.makeDirectory(DolphinProfileService.directory)
        try await storage.makeDirectory(Self.backupRoot)
        if await storage.exists(stagedManifest) { try await storage.delete(stagedManifest) }
        if await storage.exists(backupManifest) { try await storage.delete(backupManifest) }
        try await storage.write(data, to: stagedManifest)
        guard await storage.read(stagedManifest) == data else {
            throw DolphinPackError.stagedFileMismatch("manifest.txt")
        }

        var backedUp = false
        do {
            if await storage.exists(Self.manifestPath) {
                try await storage.move(Self.manifestPath, to: backupManifest)
                backedUp = true
            }
            try await storage.move(stagedManifest, to: Self.manifestPath)
            if backedUp, await storage.exists(backupManifest) {
                try? await storage.delete(backupManifest)
            }
        } catch {
            if await storage.exists(Self.manifestPath) { try? await storage.delete(Self.manifestPath) }
            if backedUp, await storage.exists(backupManifest) {
                try? await storage.move(backupManifest, to: Self.manifestPath)
            }
            throw error
        }
    }

    private func payload(for descriptor: DolphinPackDescriptor) async throws -> DolphinPackPayload {
        if let cached = try? cachedPayload(descriptor) {
            return cached
        }
        let downloaded = try await load(descriptor)
        try store(downloaded, descriptor: descriptor)
        return downloaded
    }

    private func cachedPayload(_ descriptor: DolphinPackDescriptor) throws -> DolphinPackPayload {
        let directory = cacheRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        let marker = directory.appendingPathComponent(Self.cacheMarker)
        guard try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == descriptor.cacheFingerprint else {
            throw DolphinPackError.invalidArchive
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var files: [String: Data] = [:]
        for name in names where DolphinPackArchive.isAllowedPackFilename(name) {
            files[name] = try Data(contentsOf: directory.appendingPathComponent(name))
        }
        return try DolphinPackArchive.validate(animationID: descriptor.id, files: files)
    }

    private func store(_ payload: DolphinPackPayload, descriptor: DolphinPackDescriptor) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let destination = cacheRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        let temporary = cacheRoot.appendingPathComponent(".\(descriptor.id).\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            for (name, data) in payload.files {
                try data.write(to: temporary.appendingPathComponent(name), options: .atomic)
            }
            try Data((descriptor.cacheFingerprint + "\n").utf8).write(
                to: temporary.appendingPathComponent(Self.cacheMarker),
                options: .atomic
            )
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: temporary, to: destination)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private func load(_ descriptor: DolphinPackDescriptor) async throws -> DolphinPackPayload {
        if let payloadProvider {
            return try await payloadProvider(descriptor)
        }
        switch descriptor.payload {
        case .bundled:
            return try DolphinPackArchive.loadBundled(descriptor: descriptor, bundle: bundle)
        case .remoteZip(let url, let sha256):
            let data = try await download(url)
            return try DolphinPackArchive.decode(data, descriptor: descriptor, expectedSHA256: sha256)
        case .remoteFiles(let baseURL, let remoteFiles):
            var files: [String: Data] = [:]
            var totalBytes = 0
            for remoteFile in remoteFiles {
                guard DolphinPackArchive.isAllowedPackFilename(remoteFile.name),
                      files[remoteFile.name] == nil else {
                    throw DolphinPackError.invalidArchive
                }
                let data = try await download(baseURL.appendingPathComponent(remoteFile.name))
                guard DolphinPackArchive.matchesDigest(data, expectedSHA256: remoteFile.sha256) else {
                    throw DolphinPackError.digestMismatch
                }
                totalBytes += data.count
                guard totalBytes <= DolphinPackArchive.maximumExtractedBytes else {
                    throw DolphinPackError.archiveTooLarge
                }
                files[remoteFile.name] = data
            }
            return try DolphinPackArchive.validate(animationID: descriptor.id, files: files)
        case .repositoryArchive(let url, let sha256, let rootDirectory, let animationPath):
            let data = try await download(url)
            return try DolphinPackArchive.decodeRepositoryArchive(
                data,
                descriptor: descriptor,
                expectedSHA256: sha256,
                rootDirectory: rootDirectory,
                animationPath: animationPath
            )
        }
    }

    private func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw DolphinPackError.downloadFailed
        }
        return data
    }

    private func verify(_ data: Data, at path: String) async -> Bool {
        if let remoteMD5 = await storage.deviceMD5(path) {
            let localMD5 = Insecure.MD5.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            return remoteMD5.lowercased() == localMD5
        }
        return await storage.read(path) == data
    }
}

enum DolphinAnimationManifest {
    static let empty = Data("Filetype: Flipper Animation Manifest\nVersion: 1\n".utf8)

    static func contains(_ animationID: String, in data: Data) -> Bool {
        animationIDs(in: data).contains(animationID)
    }

    static func animationIDs(in data: Data) -> Set<String> {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard line.hasPrefix("Name: ") else { return nil }
            return String(line.dropFirst("Name: ".count))
        })
    }

    static func appending(_ animationID: String, to data: Data) throws -> Data {
        guard !contains(animationID, in: data) else { return data }
        guard var text = String(data: data, encoding: .utf8),
              text.contains("Filetype: Flipper Animation Manifest"),
              text.contains("Version: 1") else {
            throw DolphinPackError.invalidManifest
        }
        while text.hasSuffix("\n\n") { text.removeLast() }
        if !text.hasSuffix("\n") { text.append("\n") }
        text.append(
            """

            Name: \(animationID)
            Min butthurt: 0
            Max butthurt: 14
            Min level: 1
            Max level: 100
            Weight: 3
            """
        )
        text.append("\n")
        return Data(text.utf8)
    }

    static func replacing(with animationIDs: [String]) throws -> Data {
        var manifest = empty
        for id in animationIDs {
            manifest = try appending(id, to: manifest)
        }
        return manifest
    }
}
