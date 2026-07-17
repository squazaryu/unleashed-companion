import XCTest
import ZIPFoundation
@testable import UnleashedCompanion

final class DolphinProfileTests: XCTestCase {
    func testProfileRoundTripPreservesCollectionOrderAndTiming() throws {
        let profile = makeProfile()

        let data = try profile.encoded()

        XCTAssertEqual(try DolphinDesktopProfile.decode(data), profile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("Order: Sequential"))
        XCTAssertTrue(text.contains("Timing: Custom"))
    }

    func testEnabledProfileRequiresAnimations() {
        var profile = makeProfile()
        profile.animationIDs = []

        XCTAssertThrowsError(try profile.encoded()) { error in
            XCTAssertEqual(error as? DolphinProfileError, .emptyCollection)
        }
    }

    func testAllSelectionDoesNotSerializeHundredsOfAnimationIDs() throws {
        let profile = DolphinDesktopProfile(
            enabled: true,
            collection: "All animations",
            order: .random,
            timing: .original,
            durationSeconds: 60,
            animationIDs: [],
            selection: .all
        )

        let data = try profile.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Version: 2"))
        XCTAssertTrue(text.contains("Selection: All"))
        XCTAssertFalse(text.contains("Animation:"))
        XCTAssertEqual(try DolphinDesktopProfile.decode(data), profile)
    }

    func testVersionOneProfileRemainsReadableAsExplicitSelection() throws {
        let data = Data(
            """
            Filetype: Tumoflip Desktop Profile
            Version: 1
            Enabled: true
            Collection: Legacy
            Order: Random
            Timing: Original
            Duration: 60
            Animation: L1_Tv_128x47

            """.utf8
        )

        let profile = try DolphinDesktopProfile.decode(data)
        XCTAssertEqual(profile.selection, .explicit)
        XCTAssertEqual(profile.animationIDs, ["L1_Tv_128x47"])
    }

    func testApplyStagesVerifiesMovesAndSignalsReload() async throws {
        let storage = DolphinProfileMemoryStore()
        let service = DolphinProfileService(storage: storage)
        let profile = makeProfile()

        try await service.apply(profile)

        let installed = await storage.data(at: DolphinProfileService.profilePath)
        let reload = await storage.data(at: DolphinProfileService.reloadPath)
        let temporary = await storage.data(at: DolphinProfileService.temporaryPath)
        XCTAssertEqual(installed, try profile.encoded())
        XCTAssertEqual(reload, Data("reload\n".utf8))
        XCTAssertNil(temporary)
    }

    func testApplyReplacesExistingProfile() async throws {
        let storage = DolphinProfileMemoryStore()
        let service = DolphinProfileService(storage: storage)
        var profile = makeProfile()

        try await service.apply(profile)
        profile.durationSeconds = 120
        try await service.apply(profile)

        let installed = await storage.data(at: DolphinProfileService.profilePath)
        XCTAssertEqual(installed, try profile.encoded())
    }

    func testResetToOriginalRemovesProfileAndSignalsReload() async throws {
        let storage = DolphinProfileMemoryStore()
        let service = DolphinProfileService(storage: storage)

        try await service.apply(makeProfile())
        try await service.resetToOriginal()

        let profile = await storage.data(at: DolphinProfileService.profilePath)
        let temporary = await storage.data(at: DolphinProfileService.temporaryPath)
        let reload = await storage.data(at: DolphinProfileService.reloadPath)
        XCTAssertNil(profile)
        XCTAssertNil(temporary)
        XCTAssertEqual(reload, Data("reload\n".utf8))
    }

    func testProfileRejectsDuplicateAndNonASCIIAnimationIDs() {
        var profile = makeProfile()
        profile.animationIDs = ["L1_Tv_128x47", "L1_Tv_128x47"]
        XCTAssertThrowsError(try profile.encoded())

        profile.animationIDs = ["L1_Кот_128x47"]
        XCTAssertThrowsError(try profile.encoded())
    }

    func testProfileRejectsUnsafeCollectionName() {
        var profile = makeProfile()
        profile.collection = "Favorites\nEnabled: false"

        XCTAssertThrowsError(try profile.encoded()) { error in
            XCTAssertEqual(error as? DolphinProfileError, .invalidCollection)
        }
    }

    func testDisabledOriginalProfileAllowsNoAnimationFilter() throws {
        let profile = DolphinDesktopProfile(
            enabled: false,
            collection: "All animations",
            order: .random,
            timing: .original,
            durationSeconds: 60,
            animationIDs: []
        )

        XCTAssertEqual(try DolphinDesktopProfile.decode(profile.encoded()), profile)
    }

    func testManifestAppendPreservesExistingEntriesAndDeduplicates() throws {
        let original = Data(
            """
            Filetype: Flipper Animation Manifest
            Version: 1

            Name: Legacy
            Min butthurt: 0
            Max butthurt: 14
            Min level: 1
            Max level: 3
            Weight: 3

            """.utf8
        )

        let once = try DolphinAnimationManifest.appending("New_Animation", to: original)
        let twice = try DolphinAnimationManifest.appending("New_Animation", to: once)
        let text = String(decoding: twice, as: UTF8.self)

        XCTAssertEqual(once, twice)
        XCTAssertTrue(text.contains("Name: Legacy"))
        XCTAssertEqual(text.components(separatedBy: "Name: New_Animation").count - 1, 1)
        XCTAssertTrue(text.contains("Max level: 100"))
    }

    func testPackMetadataAllowsRepeatedPlaybackFrame() throws {
        let files = [
            "meta.txt": animationMetadata(passiveFrames: 3, order: "0 1 1"),
            "frame_0.bm": Data([0x00]),
            "frame_1.bm": Data([0x01]),
        ]

        let payload = try DolphinPackArchive.validate(animationID: "Test", files: files)

        XCTAssertEqual(payload.animationID, "Test")
        XCTAssertEqual(payload.files.count, 3)
    }

    func testPackMetadataRejectsMissingReferencedFrame() {
        let files = [
            "meta.txt": animationMetadata(passiveFrames: 2, order: "0 1"),
            "frame_0.bm": Data([0x00]),
        ]

        XCTAssertThrowsError(try DolphinPackArchive.validate(animationID: "Test", files: files)) {
            XCTAssertEqual($0 as? DolphinPackError, .missingFrames)
        }
    }

    func testPackArchiveRejectsTraversal() throws {
        let data = try makeArchive(entries: [
            "Test/meta.txt": animationMetadata(passiveFrames: 1, order: "0"),
            "Test/frame_0.bm": Data([0x00]),
            "Test/../escape.bm": Data([0xFF]),
        ])
        let descriptor = DolphinPackDescriptor(
            id: "Test",
            title: "Test",
            source: .talkingSasquach,
            author: "Test",
            sourceURL: URL(string: "https://example.com/source")!,
            previewURL: nil,
            payload: .remoteZip(
                url: URL(string: "https://example.com/test.zip")!,
                sha256: TumoflipHash.sha256(data)
            )
        )

        XCTAssertThrowsError(try DolphinPackArchive.decode(
            data,
            descriptor: descriptor,
            expectedSHA256: TumoflipHash.sha256(data)
        )) {
            XCTAssertEqual($0 as? DolphinPackError, .unsafePath)
        }
    }

    func testTalkingSasquachCatalogPinsReviewedCommitAndDigests() {
        XCTAssertEqual(DolphinPackCatalog.talkingSasquach.count, 9)
        var archiveCount = 0
        var fileTreeCount = 0
        for descriptor in DolphinPackCatalog.talkingSasquach {
            XCTAssertTrue(descriptor.sourceURL.absoluteString.contains("Finished%20Animations"))
            switch descriptor.payload {
            case .remoteZip(let url, let digest):
                archiveCount += 1
                XCTAssertTrue(url.absoluteString.contains("1088fb0fab1a875517086085e2e44c7b1d331c7e"))
                XCTAssertEqual(digest.count, 64)
            case .remoteFiles(let baseURL, let files):
                fileTreeCount += 1
                XCTAssertEqual(descriptor.id, "Sasquach_RMCF")
                XCTAssertTrue(baseURL.absoluteString.contains("1088fb0fab1a875517086085e2e44c7b1d331c7e"))
                XCTAssertEqual(files.count, 40)
                XCTAssertTrue(files.allSatisfy { $0.sha256.count == 64 })
            default:
                XCTFail("Talking Sasquach entries must use pinned source downloads")
            }
        }
        XCTAssertEqual(archiveCount, 8)
        XCTAssertEqual(fileTreeCount, 1)
    }

    func testRemoteCatalogSeparatesAuthorsAndUsesUniqueSafeIDs() {
        XCTAssertEqual(DolphinPackCatalog.kuronons.count, 130)
        XCTAssertEqual(DolphinPackCatalog.haseo.count, 28)
        XCTAssertEqual(DolphinPackCatalog.stopOxy.count, 11)
        XCTAssertEqual(DolphinPackCatalog.wr3nch.count, 63)
        XCTAssertEqual(DolphinPackCatalog.remote.count, 241)

        let ids = DolphinPackCatalog.installable.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { id in
            !id.isEmpty && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) ||
                    (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        })
    }

    func testEveryInstallablePackHasBundledPreview() {
        for descriptor in DolphinPackCatalog.installable {
            XCTAssertNotNil(
                Bundle.main.url(
                    forResource: descriptor.id,
                    withExtension: "png",
                    subdirectory: "DolphinPreviews"
                ),
                "Missing preview for \(descriptor.id)"
            )
        }
    }

    func testEveryAnimationHasBundledAnimatedPreview() {
        let animations = DolphinCatalog.legacy + DolphinPackCatalog.installable.map(\.animation)
        for animation in animations {
            XCTAssertNotNil(
                Bundle.main.url(
                    forResource: animation.id,
                    withExtension: "gif",
                    subdirectory: "DolphinAnimations"
                ),
                "Missing animated preview for \(animation.id)"
            )
        }
    }

    @MainActor
    func testLocalDurationSurvivesModelRecreationAndSuppressesAutomaticImport() {
        let suiteName = "DolphinGalleryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = DolphinGalleryModel(defaults: defaults)
        XCTAssertTrue(initial.shouldLoadInitialProfileFromDevice)
        initial.timing = .custom
        initial.durationSeconds = 137

        let restored = DolphinGalleryModel(defaults: defaults)
        XCTAssertFalse(restored.shouldLoadInitialProfileFromDevice)
        XCTAssertEqual(restored.timing, .custom)
        XCTAssertEqual(restored.durationSeconds, 137)
    }

    func testRepositoryArchiveExtractsOnlySelectedAnimation() throws {
        let data = try makeArchive(entries: [
            "Repo-abc/Animations/TestPack/meta.txt": animationMetadata(passiveFrames: 1, order: "0"),
            "Repo-abc/Animations/TestPack/frame_0.bm": Data([0x01]),
            "Repo-abc/Animations/OtherPack/meta.txt": Data("ignored".utf8),
        ])
        let descriptor = DolphinPackDescriptor(
            id: "TestPack",
            title: "Test Pack",
            source: .haseo,
            author: "Tests",
            sourceURL: URL(string: "https://example.com/source")!,
            previewURL: nil,
            payload: .repositoryArchive(
                url: URL(string: "https://example.com/repo.zip")!,
                sha256: TumoflipHash.sha256(data),
                rootDirectory: "Repo-abc",
                animationPath: "Animations/TestPack"
            )
        )

        let payload = try DolphinPackArchive.decodeRepositoryArchive(
            data,
            descriptor: descriptor,
            expectedSHA256: TumoflipHash.sha256(data),
            rootDirectory: "Repo-abc",
            animationPath: "Animations/TestPack"
        )

        XCTAssertEqual(Set(payload.files.keys), ["meta.txt", "frame_0.bm"])
    }

    func testBundledMomentumPacksValidate() throws {
        for descriptor in DolphinPackCatalog.momentum {
            let payload = try DolphinPackArchive.loadBundled(
                descriptor: descriptor,
                bundle: .main
            )
            XCTAssertEqual(payload.animationID, descriptor.id)
            XCTAssertNotNil(payload.files["meta.txt"])
        }
    }

    func testPackInstallerCommitsFilesManifestAndReloadMarker() async throws {
        let storage = DolphinPackMemoryFS()
        storage.files[DolphinPackInstaller.manifestPath] = DolphinAnimationManifest.empty
        let descriptor = testPackDescriptor()
        let cacheRoot = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let installer = DolphinPackInstaller(
            storage: storage,
            cacheRoot: cacheRoot,
            payloadProvider: { _ in self.testPackPayload() }
        )

        try await installer.install(descriptor)

        XCTAssertEqual(
            storage.files["/ext/dolphin/TestPack/frame_0.bm"],
            Data([0x01, 0x02])
        )
        let manifest = try XCTUnwrap(storage.files[DolphinPackInstaller.manifestPath])
        XCTAssertTrue(DolphinAnimationManifest.contains("TestPack", in: manifest))
        XCTAssertEqual(
            storage.files[DolphinProfileService.reloadPath],
            Data("reload\n".utf8)
        )
        XCTAssertFalse(storage.files.keys.contains { $0.contains(".tumocompanion-stage") })
    }

    func testPackInstallerRestoresPreviousPackWhenManifestActivationFails() async {
        let storage = DolphinPackMemoryFS()
        let oldManifest = try! DolphinAnimationManifest.appending(
            "TestPack",
            to: DolphinAnimationManifest.empty
        )
        storage.files[DolphinPackInstaller.manifestPath] = oldManifest
        storage.dirs.insert("/ext/dolphin/TestPack")
        storage.files["/ext/dolphin/TestPack/frame_0.bm"] = Data("old".utf8)
        storage.files["/ext/dolphin/TestPack/meta.txt"] = Data("old-meta".utf8)
        storage.failMove = { from, to in
            from.hasSuffix("manifest.txt.new") && to == DolphinPackInstaller.manifestPath
        }
        let cacheRoot = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let installer = DolphinPackInstaller(
            storage: storage,
            cacheRoot: cacheRoot,
            payloadProvider: { _ in self.testPackPayload() }
        )

        do {
            try await installer.install(testPackDescriptor())
            XCTFail("Expected an injected activation failure")
        } catch {}

        XCTAssertEqual(storage.files[DolphinPackInstaller.manifestPath], oldManifest)
        XCTAssertEqual(
            storage.files["/ext/dolphin/TestPack/frame_0.bm"],
            Data("old".utf8)
        )
        XCTAssertNil(storage.files[DolphinProfileService.reloadPath])
    }

    func testSynchronizeReplacesManagedManifestAndDeletesUnselectedPack() async throws {
        let storage = DolphinPackMemoryFS()
        let selected = DolphinPackCatalog.momentum[0]
        let stale = DolphinPackCatalog.momentum[1]
        storage.files[DolphinPackInstaller.manifestPath] = try DolphinAnimationManifest.replacing(
            with: [stale.id]
        )
        storage.dirs.insert("/ext/dolphin/\(stale.id)")
        storage.files["/ext/dolphin/\(stale.id)/meta.txt"] = Data("stale".utf8)
        let cacheRoot = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let installer = DolphinPackInstaller(
            storage: storage,
            cacheRoot: cacheRoot,
            payloadProvider: { descriptor in self.testPackPayload(id: descriptor.id) }
        )
        let progress = DolphinProgressRecorder()

        try await installer.synchronize([selected]) { update in
            await progress.append(update)
        }

        let manifest = try XCTUnwrap(storage.files[DolphinPackInstaller.manifestPath])
        let updates = await progress.values
        XCTAssertEqual(DolphinAnimationManifest.animationIDs(in: manifest), Set([selected.id]))
        XCTAssertNotNil(storage.files["/ext/dolphin/\(selected.id)/meta.txt"])
        XCTAssertNil(storage.files["/ext/dolphin/\(stale.id)/meta.txt"])
        XCTAssertEqual(storage.files[DolphinProfileService.reloadPath], Data("reload\n".utf8))
        XCTAssertEqual(Set(updates.map(\.stage)), [.caching, .uploading, .removing])
        XCTAssertEqual(updates.last(where: { $0.stage == .uploading })?.completed, 1)
        XCTAssertEqual(updates.last(where: { $0.stage == .removing })?.completed, 1)
    }

    func testPackResetPreservesStockManifestAndRemovesManagedPacks() async throws {
        let storage = DolphinPackMemoryFS()
        let managed = DolphinPackCatalog.momentum[0]
        let stock = try DolphinAnimationManifest.replacing(with: ["L1_Tv_128x47"])
        storage.files[DolphinPackInstaller.stockManifestPath] = stock
        storage.files[DolphinPackInstaller.manifestPath] = try DolphinAnimationManifest.replacing(
            with: [managed.id]
        )
        storage.dirs.insert("/ext/dolphin/\(managed.id)")
        storage.files["/ext/dolphin/\(managed.id)/meta.txt"] = Data("managed".utf8)
        let cacheRoot = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let installer = DolphinPackInstaller(storage: storage, cacheRoot: cacheRoot)

        try await installer.resetToOriginal()

        XCTAssertEqual(storage.files[DolphinPackInstaller.stockManifestPath], stock)
        XCTAssertNil(storage.files[DolphinPackInstaller.manifestPath])
        XCTAssertNil(storage.files["/ext/dolphin/\(managed.id)/meta.txt"])
    }

    private func makeProfile() -> DolphinDesktopProfile {
        DolphinDesktopProfile(
            enabled: true,
            collection: "Favorites",
            order: .sequential,
            timing: .custom,
            durationSeconds: 90,
            animationIDs: ["L1_Tv_128x47", "L1_Waves_128x50"]
        )
    }

    private func animationMetadata(passiveFrames: Int, order: String) -> Data {
        Data(
            """
            Filetype: Flipper Animation
            Version: 1

            Width: 128
            Height: 64
            Passive frames: \(passiveFrames)
            Active frames: 0
            Frames order: \(order)
            Active cycles: 0
            Frame rate: 6
            Duration: 60
            Active cooldown: 0

            Bubble slots: 0
            """.utf8
        )
    }

    private func testPackDescriptor() -> DolphinPackDescriptor {
        DolphinPackDescriptor(
            id: "TestPack",
            title: "Test Pack",
            source: .momentum,
            author: "Tests",
            sourceURL: URL(string: "https://example.com/source")!,
            previewURL: nil,
            payload: .bundled(resourcePath: "unused")
        )
    }

    private func testPackPayload(id: String = "TestPack") -> DolphinPackPayload {
        DolphinPackPayload(animationID: id, files: [
            "meta.txt": animationMetadata(passiveFrames: 1, order: "0"),
            "frame_0.bm": Data([0x01, 0x02]),
        ])
    }

    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DolphinPackTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeArchive(entries: [String: Data]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try Data(contentsOf: url)
    }
}

private final class DolphinPackMemoryFS: TumoflipDeviceFS, @unchecked Sendable {
    enum Failure: Error { case injected, missing }

    var files: [String: Data] = [:]
    var dirs: Set<String> = []
    var failMove: ((String, String) -> Bool)?

    func write(_ data: Data, to path: String) async throws {
        files[path] = data
    }

    func read(_ path: String) async -> Data? {
        files[path]
    }

    func deviceMD5(_ path: String) async -> String? {
        files[path].map(TumoflipHash.md5)
    }

    func move(_ from: String, to: String) async throws {
        if failMove?(from, to) == true { throw Failure.injected }
        if let data = files.removeValue(forKey: from) {
            files[to] = data
            return
        }
        guard dirs.contains(from) else { throw Failure.missing }
        let movedFiles = files.filter { $0.key.hasPrefix(from + "/") }
        for (path, data) in movedFiles {
            files.removeValue(forKey: path)
            files[to + path.dropFirst(from.count)] = data
        }
        let movedDirs = dirs.filter { $0 == from || $0.hasPrefix(from + "/") }
        dirs.subtract(movedDirs)
        dirs.formUnion(movedDirs.map { to + $0.dropFirst(from.count) })
    }

    func delete(_ path: String) async throws {
        files.removeValue(forKey: path)
    }

    func deleteTree(_ path: String) async throws {
        files = files.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        dirs = dirs.filter { $0 != path && !$0.hasPrefix(path + "/") }
    }

    func makeDirectory(_ path: String) async throws {
        dirs.insert(path)
    }

    func exists(_ path: String) async -> Bool {
        files[path] != nil || dirs.contains(path)
    }
}

private actor DolphinProfileMemoryStore: DolphinProfileFileStore {
    private var files: [String: Data] = [:]

    func read(_ path: String) async throws -> Data {
        guard let data = files[path] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }

    func write(_ path: String, data: Data) async throws {
        files[path] = data
    }

    func makeDirectory(_ path: String) async throws {}

    func delete(_ path: String) async throws {
        files.removeValue(forKey: path)
    }

    func move(_ from: String, to newPath: String) async throws {
        guard files[newPath] == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard let data = files.removeValue(forKey: from) else {
            throw CocoaError(.fileNoSuchFile)
        }
        files[newPath] = data
    }

    func exists(_ path: String) async -> Bool {
        files[path] != nil
    }

    func data(at path: String) -> Data? {
        files[path]
    }
}

private actor DolphinProgressRecorder {
    private(set) var values: [DolphinPackSyncProgress] = []

    func append(_ value: DolphinPackSyncProgress) {
        values.append(value)
    }
}
