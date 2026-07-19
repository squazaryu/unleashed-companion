import SWCompression
import XCTest
@testable import UnleashedCompanion

final class FirmwareArchiveTests: XCTestCase {
    func testValidUpdaterArchiveIsDecodedInInstallOrder() throws {
        let directory = "f7-update-t-dev-089-040-001"
        let archive = try makeArchive(
            directory: directory,
            names: FirmwareArchive.requiredFiles)

        let files = try FirmwareArchive.decode(archive, expectedDirectory: directory)

        XCTAssertEqual(files.map(\.name), FirmwareArchive.requiredFiles)
        XCTAssertEqual(files.last?.name, "update.fuf")
    }

    func testArchiveRejectsTraversal() throws {
        let directory = "f7-update-t-dev-089-040-001"
        var entries = FirmwareArchive.requiredFiles.map { "\(directory)/\($0)" }
        entries[0] = "\(directory)/../firmware.dfu"
        let archive = try makeArchive(paths: entries)

        XCTAssertThrowsError(try FirmwareArchive.decode(archive, expectedDirectory: directory)) {
            guard case FirmwareLibraryError.invalidArchive = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testArchiveRejectsMissingUpdaterFile() throws {
        let directory = "f7-update-t-dev-089-040-001"
        let archive = try makeArchive(
            directory: directory,
            names: FirmwareArchive.requiredFiles.filter { $0 != "update.fuf" })

        XCTAssertThrowsError(try FirmwareArchive.decode(archive, expectedDirectory: directory)) {
            guard case FirmwareLibraryError.invalidArchive = $0 else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    private func makeArchive(directory: String, names: [String]) throws -> Data {
        try makeArchive(paths: names.map { "\(directory)/\($0)" })
    }

    private func makeArchive(paths: [String]) throws -> Data {
        let entries = paths.map { path -> TarEntry in
            let info = TarEntryInfo(name: path, type: .regular)
            return TarEntry(info: info, data: Data(path.utf8))
        }
        return try GzipArchive.archive(data: TarContainer.create(from: entries))
    }
}
