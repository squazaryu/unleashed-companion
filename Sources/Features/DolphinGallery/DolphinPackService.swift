import CryptoKit
import Foundation
import ZIPFoundation

enum DolphinLibrarySource: String, CaseIterable, Codable, Identifiable {
    case legacy = "Legacy"
    case momentum = "Momentum"
    case talkingSasquach = "Talking Sasquach"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .legacy: return "archivebox"
        case .momentum: return "bolt.horizontal.circle"
        case .talkingSasquach: return "person.wave.2"
        }
    }
}

struct DolphinPackDescriptor: Identifiable, Hashable {
    enum Payload: Hashable {
        case bundled(resourcePath: String)
        case remoteZip(url: URL, sha256: String)
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
}

enum DolphinPackCatalog {
    static let momentumRepository = URL(string: "https://github.com/Next-Flip/Momentum-Firmware")!
    static let talkingSasquachRepository = URL(string: "https://github.com/skizzophrenic/Talking-Sasquach")!

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

    static let talkingSasquach: [DolphinPackDescriptor] = [
        talkingPack(
            id: "Sasquach_Blaster",
            title: "Blaster",
            zipPath: "Finished Animations/Sasquach_Blaster/Sasquach_Blaster.zip",
            sha256: "f31c1215adfa1010efe2b94124d846b42ad3ccb0147961a8e4efbf1dea9fc74c"
        ),
        talkingPack(
            id: "Sasquach_CloudGoku",
            title: "Cloud Goku",
            zipPath: "Finished Animations/Sasquach_CloudGoku/Sasquach_CloudGoku.zip",
            sha256: "9cb46bf711fbeb01de4703fb0d04db29778d7ce0d2bb4ad25ba0e7780dce57e8"
        ),
        talkingPack(
            id: "Sasquach_D1g1talRa1n",
            title: "Digital Rain",
            zipPath: "Finished Animations/Sasquach_D1g1talRa1n/Sasquach_D1g1talRa1n.zip",
            sha256: "2362b1e8f1ea286b527a86b58b662c7c1fbe6ed89f4cc60bdef32646e436ddb6"
        ),
        talkingPack(
            id: "Sasquach_Goku",
            title: "Goku",
            zipPath: "Finished Animations/Sasquach_Goku/Sasquach_Goku.zip",
            sha256: "5f73336c8f7c9e37360bb0861beb4e874aa1f924a7e0a33602838d1c23bb0e35"
        ),
        talkingPack(
            id: "Sasquach_Naruto",
            title: "Naruto",
            zipPath: "Finished Animations/Sasquach_Naruto/Sasquach_Naruto.zip",
            sha256: "e4611406b94008e79c80671549b42846683c3bd2536e95bf6f47a2c3b653844e"
        ),
        talkingPack(
            id: "Sasquach_SaladFingers_128x64",
            title: "Salad Fingers",
            zipPath: "Finished Animations/Sasquach_SaladFingers_128x64/Sasquach_SaladFingers_128x64.zip",
            sha256: "2a49a0a7117ed888ff8687861f3f08483a9a3e8c6a8799edc77b7f4e8b182eed"
        ),
        talkingPack(
            id: "Sasquach_StickFight_128x64",
            title: "Stick Fight",
            zipPath: "Finished Animations/Sasquach_StickFight_128x64/Sasquach_StickFight_128x64.zip",
            sha256: "8028464bcad23a715a1d3549da850840bf4dbfc60a85c99d95fb9de5289c19da"
        ),
        talkingPack(
            id: "axolotl",
            title: "Axolotl",
            zipPath: "Finished Animations/axolotl/axolotl.zip",
            sha256: "56ca349ce1adfc31545b86203a79a7e56208b8a1c8c6d4463b8b2e2306ab0e66"
        ),
    ]

    static let installable = momentum + talkingSasquach

    private static let talkingCommit = "1088fb0fab1a875517086085e2e44c7b1d331c7e"

    private static func talkingPack(
        id: String,
        title: String,
        zipPath: String,
        sha256: String
    ) -> DolphinPackDescriptor {
        let encodedPath = zipPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        let url = rawURL(
            "https://raw.githubusercontent.com/skizzophrenic/Talking-Sasquach/\(talkingCommit)/\(encodedPath)"
        )
        return DolphinPackDescriptor(
            id: id,
            title: title,
            source: .talkingSasquach,
            author: "Talking Sasquach",
            sourceURL: talkingSasquachRepository,
            previewURL: nil,
            payload: .remoteZip(url: url, sha256: sha256)
        )
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
    static let maximumExtractedBytes = 2 * 1_024 * 1_024
    static let maximumEntries = 512
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
        guard !frameIndexes.isEmpty,
              frameIndexes.count <= maximumFrames,
              frameIndexes == referencedFrameIndexes else {
            throw DolphinPackError.missingFrames
        }
        return DolphinPackPayload(animationID: animationID, files: files)
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

struct DolphinPackInstaller {
    static let dolphinRoot = "/ext/dolphin"
    static let manifestPath = "\(dolphinRoot)/manifest.txt"
    static let stagingRoot = "\(dolphinRoot)/.tumocompanion-stage"
    static let backupRoot = "\(DolphinProfileService.directory)/dolphin-pack-backup"

    let storage: any TumoflipDeviceFS
    let bundle: Bundle
    let session: URLSession
    private let payloadProvider: ((DolphinPackDescriptor) async throws -> DolphinPackPayload)?

    init(
        storage: any TumoflipDeviceFS = FlipperDeviceFS(),
        bundle: Bundle = .main,
        session: URLSession = .shared,
        payloadProvider: ((DolphinPackDescriptor) async throws -> DolphinPackPayload)? = nil
    ) {
        self.storage = storage
        self.bundle = bundle
        self.session = session
        self.payloadProvider = payloadProvider
    }

    func isInstalled(_ descriptor: DolphinPackDescriptor) async -> Bool {
        guard await storage.exists("\(Self.dolphinRoot)/\(descriptor.id)/meta.txt"),
              let manifest = await storage.read(Self.manifestPath) else {
            return false
        }
        return DolphinAnimationManifest.contains(descriptor.id, in: manifest)
    }

    func install(_ descriptor: DolphinPackDescriptor) async throws {
        let payload = try await load(descriptor)
        let stagedDirectory = "\(Self.stagingRoot)/\(descriptor.id)"
        let finalDirectory = "\(Self.dolphinRoot)/\(descriptor.id)"
        let backupDirectory = "\(Self.backupRoot)/\(descriptor.id)"
        let stagedManifest = "\(Self.backupRoot)/manifest.txt.new"
        let backupManifest = "\(Self.backupRoot)/manifest.txt.previous"

        try await storage.makeDirectory(Self.stagingRoot)
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

    private func load(_ descriptor: DolphinPackDescriptor) async throws -> DolphinPackPayload {
        if let payloadProvider {
            return try await payloadProvider(descriptor)
        }
        switch descriptor.payload {
        case .bundled:
            return try DolphinPackArchive.loadBundled(descriptor: descriptor, bundle: bundle)
        case .remoteZip(let url, let sha256):
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else {
                throw DolphinPackError.downloadFailed
            }
            return try DolphinPackArchive.decode(data, descriptor: descriptor, expectedSHA256: sha256)
        }
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
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: { $0.isNewline }).contains { line in
            line == "Name: \(animationID)"
        }
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
}
