import XCTest
@testable import UnleashedCompanion

/// Regression test for the Apps Market install 404: the catalog build-asset URL
/// must put the VERSION's `_id` in the `version/` path segment, never the build
/// document's `_id`. Using the build id 404s for every app (verified against the
/// live catalog API — build-id → 404, version-id → 200 with a matching fap_hash).
final class CatalogClientTests: XCTestCase {

    func testBuildAssetPathUsesVersionIDNotBuildID() {
        let build = CatalogBuild(id: "BUILD_DOC_ID",
                                 sdk: CatalogSDK(target: "f7", api: "87.1"),
                                 fapHash: "deadbeef")
        let path = FlipperCatalogClient.buildAssetPath(versionID: "VERSION_DOC_ID", build: build)

        XCTAssertEqual(path, "application/version/VERSION_DOC_ID/build/f7/87.1")
        XCTAssertTrue(path.contains("version/VERSION_DOC_ID/"),
                      "version segment must carry the version id")
        XCTAssertFalse(path.contains("BUILD_DOC_ID"),
                       "build._id must never appear in the version path segment (the 404 bug)")
    }

    func testBuildAssetPathCarriesBuildSDKTargetAndApi() {
        let build = CatalogBuild(id: "b",
                                 sdk: CatalogSDK(target: "f18", api: "88.0"),
                                 fapHash: "x")
        XCTAssertEqual(FlipperCatalogClient.buildAssetPath(versionID: "v", build: build),
                       "application/version/v/build/f18/88.0")
    }
}
