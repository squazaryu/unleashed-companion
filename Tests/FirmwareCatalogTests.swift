import XCTest
@testable import UnleashedCompanion

final class FirmwareCatalogTests: XCTestCase {
    func testCatalogSeparatesStableAndDevReleases() throws {
        let releases = try FirmwareCatalog.decode(Data(json.utf8))

        XCTAssertEqual(releases.map(\.version), ["t-dev-089-040-001", "t-flppr-fw-089-039"])
        XCTAssertEqual(releases.map(\.channel), [.dev, .stable])
        XCTAssertEqual(releases.first?.updaterSHA256, String(repeating: "a", count: 64))
    }

    func testCatalogRejectsMismatchedPrereleaseChannel() throws {
        let changed = json.replacingOccurrences(
            of: "\"prerelease\": true",
            with: "\"prerelease\": false")
        let releases = try FirmwareCatalog.decode(Data(changed.utf8))

        XCTAssertEqual(releases.map(\.version), ["t-flppr-fw-089-039"])
    }

    func testCatalogKeepsLatestReleaseForDuplicateVersion() throws {
        let duplicate = "[\(releaseJSON(tag: "new", date: "2026-07-19T10:00:00Z")),"
            + "\(releaseJSON(tag: "old", date: "2026-07-18T10:00:00Z"))]"
        let releases = try FirmwareCatalog.decode(Data(duplicate.utf8))

        XCTAssertEqual(releases.filter { $0.version == "t-dev-089-040-001" }.count, 1)
        XCTAssertEqual(releases.first?.publishedAt, ISO8601DateFormatter().date(from: "2026-07-19T10:00:00Z"))
    }

    func testReleasesAreGroupedByFirmwareVersionLine() throws {
        let releases = try FirmwareCatalog.decode(Data(groupedJSON.utf8))
        let groups = FirmwareReleaseGrouping.group(releases)

        XCTAssertEqual(groups.map(\.line), ["089-040", "089-037"])
        XCTAssertEqual(groups.map { $0.releases.count }, [2, 1])
        XCTAssertEqual(groups[0].releases.map(\.buildLabel), ["Beta 002", "Beta 001"])
    }

    func testDevShowsOnlyReleasesPublishedAfterLatestMain() {
        let latestMain = release(
            version: "t-flppr-fw-089-039", channel: .stable,
            date: "2026-07-17T10:00:00Z")
        let staleDev = release(
            version: "t-dev-089-037-058", channel: .dev,
            date: "2026-07-15T10:00:00Z")
        let currentDev = release(
            version: "t-dev-089-040-001", channel: .dev,
            date: "2026-07-19T10:00:00Z")

        let visible = FirmwareReleasePolicy.visible(
            [currentDev, latestMain, staleDev], channel: .dev)

        XCTAssertEqual(visible.map(\.version), ["t-dev-089-040-001"])
    }

    func testDevFallsBackToAvailableBuildsWithoutMainRelease() {
        let dev = release(
            version: "t-dev-089-040-001", channel: .dev,
            date: "2026-07-19T10:00:00Z")

        XCTAssertEqual(
            FirmwareReleasePolicy.visible([dev], channel: .dev).map(\.version),
            ["t-dev-089-040-001"])
    }

    private func release(
        version: String,
        channel: TumoflipFirmwareChannel,
        date: String
    ) -> FirmwareRelease {
        FirmwareRelease(
            id: version,
            tag: version,
            title: version,
            version: version,
            channel: channel,
            publishedAt: ISO8601DateFormatter().date(from: date)!,
            notes: "",
            updaterURL: URL(string: "https://example.com/\(version).tgz")!,
            updaterSize: 1,
            updaterSHA256: String(repeating: "a", count: 64),
            checksumsURL: nil,
            manifestURL: nil)
    }

    private func releaseJSON(tag: String, date: String) -> String {
        """
        {
          "tag_name": "\(tag)",
          "name": "\(tag)",
          "body": "",
          "published_at": "\(date)",
          "prerelease": true,
          "draft": false,
          "assets": [
            {
              "name": "flipper-z-f7-update-t-dev-089-040-001.tgz",
              "browser_download_url": "https://example.com/\(tag).tgz",
              "size": 123,
              "digest": "sha256:\(String(repeating: "a", count: 64))"
            }
          ]
        }
        """
    }

    private let json = """
    [
      {
        "tag_name": "t-dev-089-040-001",
        "name": "Dev 040-001",
        "body": "Dev notes",
        "published_at": "2026-07-19T10:00:00Z",
        "prerelease": true,
        "draft": false,
        "assets": [
          {
            "name": "flipper-z-f7-update-t-dev-089-040-001.tgz",
            "browser_download_url": "https://example.com/dev.tgz",
            "size": 123,
            "digest": "sha256:\(String(repeating: "a", count: 64))"
          }
        ]
      },
      {
        "tag_name": "t-flppr-fw-089-039",
        "name": null,
        "body": null,
        "published_at": "2026-07-18T10:00:00Z",
        "prerelease": false,
        "draft": false,
        "assets": [
          {
            "name": "flipper-z-f7-update-t-flppr-fw-089-039.tgz",
            "browser_download_url": "https://example.com/stable.tgz",
            "size": 456,
            "digest": null
          }
        ]
      },
      {
        "tag_name": "draft",
        "name": "Draft",
        "body": "",
        "published_at": null,
        "prerelease": false,
        "draft": true,
        "assets": []
      }
    ]
    """

    private let groupedJSON = """
    [
      {
        "tag_name": "t-dev-089-040-002", "name": "040-002", "body": "",
        "published_at": "2026-07-20T10:00:00Z", "prerelease": true, "draft": false,
        "assets": [{"name": "flipper-z-f7-update-t-dev-089-040-002.tgz", "browser_download_url": "https://example.com/002.tgz", "size": 123, "digest": "sha256:\(String(repeating: "a", count: 64))"}]
      },
      {
        "tag_name": "t-dev-089-040-001", "name": "040-001", "body": "",
        "published_at": "2026-07-19T10:00:00Z", "prerelease": true, "draft": false,
        "assets": [{"name": "flipper-z-f7-update-t-dev-089-040-001.tgz", "browser_download_url": "https://example.com/001.tgz", "size": 123, "digest": "sha256:\(String(repeating: "a", count: 64))"}]
      },
      {
        "tag_name": "t-dev-089-037-058", "name": "037-058", "body": "",
        "published_at": "2026-07-15T10:00:00Z", "prerelease": true, "draft": false,
        "assets": [{"name": "flipper-z-f7-update-t-dev-089-037-058.tgz", "browser_download_url": "https://example.com/058.tgz", "size": 123, "digest": "sha256:\(String(repeating: "a", count: 64))"}]
      }
    ]
    """
}
