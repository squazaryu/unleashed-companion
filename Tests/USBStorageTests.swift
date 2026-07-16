import XCTest
import CryptoKit
@testable import UnleashedCompanion

/// Tests for the USB SD Mode file store (issue: iOS USB polish). Pure FileManager —
/// no device, no security-scoped URL needed (a plain temp dir exercises the same code).
final class USBStorageTests: XCTestCase {

    /// Thread-safe counter for the @Sendable progress callback (called off-main).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var v = 0
        func set(_ x: Int) { lock.lock(); v = x; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    }

    private func tempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usbsd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Path mapping + traversal guard

    func testLocalURLMapping() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let s = USBSDStorage(rootURL: root)
        XCTAssertEqual(try s.localURL(for: "/").path, root.path)
        XCTAssertEqual(try s.localURL(for: "/ext").path, root.path)
        XCTAssertEqual(try s.localURL(for: "/ext/apps/Sub-GHz/x.sub").path,
                       root.appendingPathComponent("apps/Sub-GHz/x.sub").path)
    }

    func testLocalURLRejectsTraversalAndNonExt() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let s = USBSDStorage(rootURL: root)
        for bad in ["/ext/../secret", "/ext/a/../../b", "/ext/./x", "/int/foo", "/apps/x", "relative"] {
            XCTAssertThrowsError(try s.localURL(for: bad), "should reject \(bad)")
        }
    }

    // MARK: - Chunked write + read + md5 round-trip

    func testWriteReadMD5RoundTrip() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let s = USBSDStorage(rootURL: root)
        // Larger than one 256 KB chunk so the chunked-progress path is exercised.
        let data = Data((0..<(600 * 1024)).map { UInt8($0 & 0xFF) })
        let progress = Counter()
        try await s.write("/ext/apps_data/test/blob.bin", data: data) { progress.set($0) }
        XCTAssertEqual(progress.value, data.count)

        let back = try await s.read("/ext/apps_data/test/blob.bin")
        XCTAssertEqual(back, data)

        let expected = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let actual = await s.md5("/ext/apps_data/test/blob.bin")
        XCTAssertEqual(actual, expected)
    }

    // MARK: - list / exists / move / delete

    func testListExistsMoveDelete() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let s = USBSDStorage(rootURL: root)
        try await s.write("/ext/a.txt", data: Data("hi".utf8))
        try await s.makeDirectory("/ext/sub")

        let entries = try await s.list("/ext")
        XCTAssertTrue(entries.contains { $0.name == "a.txt" && !$0.isDirectory })
        XCTAssertTrue(entries.contains { $0.name == "sub" && $0.isDirectory })

        let existsBefore = await s.exists("/ext/a.txt")
        XCTAssertTrue(existsBefore)
        try await s.move("/ext/a.txt", to: "/ext/sub/a.txt")
        let existsOld = await s.exists("/ext/a.txt")
        let existsNew = await s.exists("/ext/sub/a.txt")
        XCTAssertFalse(existsOld)
        XCTAssertTrue(existsNew)

        try await s.delete("/ext/sub", recursive: true)
        let existsSub = await s.exists("/ext/sub")
        XCTAssertFalse(existsSub)
    }

    func testMoveRejectsExistingDestination() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let s = USBSDStorage(rootURL: root)
        try await s.write("/ext/a.txt", data: Data("a".utf8))
        try await s.write("/ext/b.txt", data: Data("b".utf8))
        do {
            try await s.move("/ext/a.txt", to: "/ext/b.txt")
            XCTFail("move onto an existing file should throw")
        } catch { /* expected: destinationExists */ }
    }

    // MARK: - Disconnect detection

    func testReachableReflectsRootPresence() throws {
        let root = try tempRoot()
        let s = USBSDStorage(rootURL: root)
        XCTAssertTrue(s.reachable())
        try FileManager.default.removeItem(at: root)   // simulate cable unplug / mode exit
        XCTAssertFalse(s.reachable())
    }
}
