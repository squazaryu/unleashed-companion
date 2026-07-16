import XCTest
@testable import UnleashedCompanion

final class TumoflipFirmwareRoutingTests: XCTestCase {
    func testDevTumoflipVersionRoutesToDev() {
        let identity = makeIdentity(version: "t-dev-089-035-001", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .dev)
        XCTAssertEqual(route.detectedChannel, .dev)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testStableTumoflipVersionRoutesToStable() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testLegacyStableTumoflipVersionStillRoutesToStable() {
        let identity = makeIdentity(version: "tmwhflpprarf089-034", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testMalformedNewStableVersionFallsBackWithWarning() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037-001", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .unknownTumoflipVersion("t-flppr-fw-089-037-001"))
    }

    func testUnknownTumoflipVersionFallsBackToStableWithWarning() {
        let identity = makeIdentity(version: "tumoflip-local-build", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .unknownTumoflipVersion("tumoflip-local-build"))
    }

    func testNonTumoflipFirmwareFallsBackToStableWithWarning() {
        let identity = makeIdentity(version: "unlshd-089", origin: "unleashed")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .nonTumoflip(origin: "unleashed"))
    }

    func testMissingIdentityFallsBackToStableWithWarning() {
        let route = TumoflipFirmwareRouter.route(identity: nil, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .identityUnavailable)
    }

    func testManualOverrideIsExplicitAndWarned() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: .dev)

        XCTAssertEqual(route.channel, .dev)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertEqual(route.warning, .manualOverride(selected: .dev, detected: .stable))
        XCTAssertTrue(route.isManualOverride)
    }

    func testDeviceInfoParsingKeepsUsefulDiagnostics() {
        let identity = TumoflipDeviceIdentity(deviceInfo: [
            ("firmware_version", "t-dev-089-035-001"),
            ("firmware_origin_fork", "tumoflip"),
            ("firmware_commit", "abc123"),
            ("firmware_commit_dirty", "true"),
            ("firmware_api_major", "87"),
            ("firmware_api_minor", "16"),
            ("hardware_target", "7"),
        ])

        XCTAssertEqual(identity.inferredChannel, .dev)
        XCTAssertEqual(identity.firmwareAPI, "87.16")
        XCTAssertEqual(identity.hardwareTarget, 7)
        XCTAssertEqual(identity.firmwareCommit, "abc123")
        XCTAssertEqual(identity.firmwareCommitDirty, true)
    }

    func testPackageReleaseMatcherRequiresExactInstalledDevVersion() {
        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-058",
            channel: .dev,
            installedVersion: "t-dev-089-037-058"
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-012",
            channel: .dev,
            installedVersion: "t-dev-089-037-058"
        ))
    }

    func testPackageReleaseMatcherStillFiltersChannelWithoutIdentity() {
        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-058",
            channel: .dev,
            installedVersion: nil
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-flppr-fw-089-037",
            channel: .dev,
            installedVersion: nil
        ))
    }

    private func makeIdentity(version: String, origin: String) -> TumoflipDeviceIdentity {
        TumoflipDeviceIdentity(
            firmwareVersion: version,
            originFork: origin,
            firmwareCommit: nil,
            firmwareCommitDirty: nil,
            firmwareAPI: "87.16",
            hardwareTarget: 7
        )
    }
}
