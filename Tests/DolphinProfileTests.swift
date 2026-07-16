import XCTest
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
