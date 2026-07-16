import XCTest
@testable import UnleashedCompanion

/// Tests for the FAB2 Runtime diagnostics layer (issue #15): typed capability
/// parsing (compact `feat` vs legacy `features`), and the `status`/`trace`/`twin`
/// payload parsers, verified against the exact wire format emitted by
/// `tumoflip_runtime.c` (`TUMOFLIP_RUNTIME_CAPABILITIES` and the
/// `tumoflip_runtime_make_*_payload` snprintf formats).
final class RuntimeDiagnosticsTests: XCTestCase {

    // MARK: - Capabilities: compact `feat` (current firmware)

    func testCompactFeatCapabilities() {
        // The exact string emitted by TUMOFLIP_RUNTIME_CAPABILITIES.
        let raw = FlipperBLE.parseCapabilities(Data(
            "runtime=1;fab=2;session=3;status=2;trace=1;twin=1;pkg=1;radio=2;sd=1;fabric=1;feat=pkg,radio,trace,twin,transfer,fabric".utf8))
        let caps = RuntimeCapabilities(raw)

        XCTAssertTrue(caps.supportsStatus)
        XCTAssertTrue(caps.supportsTrace)
        XCTAssertTrue(caps.supportsTwin)
        XCTAssertTrue(caps.supportsPackages)
        XCTAssertTrue(caps.supportsRadio)
        XCTAssertTrue(caps.supportsTransferActivity)
        XCTAssertTrue(caps.supportsFabric)
        XCTAssertEqual(caps.sessionVersion, 3)
    }

    func testCompactFeatWithoutTransferDoesNotEnableTransferActivity() {
        let raw = FlipperBLE.parseCapabilities(Data(
            "runtime=1;fab=2;session=3;status=2;trace=1;twin=1;pkg=1;radio=2;sd=1;feat=pkg,radio,trace,twin".utf8))
        let caps = RuntimeCapabilities(raw)

        XCTAssertFalse(caps.supportsTransferActivity)
        XCTAssertFalse(caps.supportsFabric)
    }

    // MARK: - Capabilities: legacy `features` (older firmware)

    func testLegacyFeaturesCapabilities() {
        let raw = FlipperBLE.parseCapabilities(Data(
            "runtime=1;fab=2;session=3;status=2;packages=1;radio=2;sd=1;"
            .appending("features=transfer_activity,pkg_state,radio_v2").utf8))
        let caps = RuntimeCapabilities(raw)

        XCTAssertTrue(caps.supportsStatus)
        XCTAssertTrue(caps.supportsPackages)   // via legacy token pkg_state
        XCTAssertTrue(caps.supportsRadio)      // via legacy token radio_v2
        XCTAssertTrue(caps.supportsTransferActivity)
        // Older firmware never advertised trace/twin at all.
        XCTAssertFalse(caps.supportsTrace)
        XCTAssertFalse(caps.supportsTwin)
        XCTAssertFalse(caps.supportsFabric)
    }

    func testNoCapabilitiesMeansNoFeatures() {
        let caps = RuntimeCapabilities([:])
        XCTAssertFalse(caps.supportsStatus)
        XCTAssertFalse(caps.supportsTrace)
        XCTAssertFalse(caps.supportsTwin)
        XCTAssertFalse(caps.supportsTransferActivity)
        XCTAssertFalse(caps.supportsFabric)
        XCTAssertNil(caps.sessionVersion)
    }

    // MARK: - `runtime/status` (schema v2)

    func testStatusSchemaV2Parsing() {
        // Exact shape from tumoflip_runtime_make_status_payload's snprintf format.
        let payload = "schema=2;fw=1.4.0000;commit=0d51e938;dirty=0;origin=tumo;api=87.17;target=7;"
            + "transfer=0;sd=1;pkg=1;sid=1234ABCD;bo=iphone__;radio=4;owner=squa"
        let status = RuntimeStatus(payload)

        XCTAssertEqual(status?.schema, 2)
        XCTAssertEqual(status?.firmwareVersion, "1.4.0000")
        XCTAssertEqual(status?.commit, "0d51e938")
        XCTAssertEqual(status?.dirty, false)
        XCTAssertEqual(status?.origin, "tumo")
        XCTAssertEqual(status?.api, "87.17")
        XCTAssertEqual(status?.target, 7)
        XCTAssertEqual(status?.sdReady, true)
        XCTAssertEqual(status?.packageStatePresent, true)
        XCTAssertEqual(status?.sessionID, "1234ABCD")
        XCTAssertEqual(status?.bridgeOwner, "iphone__")
        XCTAssertEqual(status?.radioState, 4)
        XCTAssertEqual(status?.radioStateLabel, "RX")
        XCTAssertEqual(status?.owner, "squa")
    }

    func testStatusNoSessionOwnerSinceBoot() {
        let status = RuntimeStatus("schema=2;fw=1.0;commit=abcd1234;dirty=1;origin=unle;api=87.1;target=7;"
                                   + "transfer=0;sd=0;pkg=0;sid=00000000;bo=;radio=0;owner=")
        XCTAssertEqual(status?.sessionID, "00000000")
        XCTAssertEqual(status?.sdReady, false)
        XCTAssertEqual(status?.dirty, true)
        XCTAssertEqual(status?.radioStateLabel, "Idle")
    }

    func testStatusMalformedPayloadReturnsNil() {
        XCTAssertNil(RuntimeStatus(""))
        XCTAssertNil(RuntimeStatus("fw=1.0;commit=abcd"))   // missing schema
    }

    // MARK: - `runtime/trace` (schema v1)

    func testTraceSchemaV1Parsing() {
        // The doc's own worked example: a request received, then its reply — e.g.
        // "status" -> "status" (first char 's' for both request and response command).
        let trace = RuntimeTrace("schema=1;depth=8;count=2;drop=0|r,s,o|t,s,o")

        XCTAssertEqual(trace?.schema, 1)
        XCTAssertEqual(trace?.depth, 8)
        XCTAssertEqual(trace?.count, 2)
        XCTAssertEqual(trace?.dropped, 0)
        XCTAssertEqual(trace?.entries.count, 2)
        XCTAssertEqual(trace?.entries[0].code, "r")
        XCTAssertEqual(trace?.entries[0].command, "s")
        XCTAssertEqual(trace?.entries[0].ok, true)
        XCTAssertEqual(trace?.entries[0].codeLabel, "recv")
        XCTAssertEqual(trace?.entries[1].code, "t")
        XCTAssertEqual(trace?.entries[1].codeLabel, "reply")
    }

    func testTraceSessionCode() {
        // A real `hello` success sequence per tumoflip_runtime_handle_request:
        // (1) 'r' received, command="hello" -> first char 'h';
        // (2) 's' session claimed, command=owner ("iphone") -> first char 'i';
        // (3) 't' successful reply, command="hello" -> first char 'h' again.
        let trace = RuntimeTrace("schema=1;depth=8;count=3;drop=1|r,h,o|s,i,o|t,h,o")

        XCTAssertEqual(trace?.entries.count, 3)
        XCTAssertEqual(trace?.dropped, 1)
        XCTAssertEqual(trace?.entries[1].code, "s")
        XCTAssertEqual(trace?.entries[1].command, "i")
        XCTAssertEqual(trace?.entries[1].ok, true)
        XCTAssertEqual(trace?.entries[1].codeLabel, "session")
    }

    func testTraceWithErrorEntry() {
        let trace = RuntimeTrace("schema=1;depth=8;count=2;drop=0|r,c,o|e,c,e")
        XCTAssertEqual(trace?.entries[1].code, "e")
        XCTAssertEqual(trace?.entries[1].ok, false)
        XCTAssertEqual(trace?.entries[1].codeLabel, "error")
    }

    func testTraceEmptyRing() {
        // count=0 → header only, no trailing "|" entries at all.
        let trace = RuntimeTrace("schema=1;depth=8;count=0;drop=0")
        XCTAssertEqual(trace?.count, 0)
        XCTAssertEqual(trace?.dropped, 0)
        XCTAssertEqual(trace?.entries, [])
    }

    func testTraceWithoutDropKeepsLegacyCompatibility() {
        let trace = RuntimeTrace("schema=1;depth=8;count=1|r,s,o")
        XCTAssertNil(trace?.dropped)
        XCTAssertEqual(trace?.entries.count, 1)
    }

    func testTraceDropAtUInt32Max() {
        // Firmware emits `drop` as %lu (uint32); mirror validate_release.py's own
        // boundary vector so the full uint32 range round-trips through Int.
        let trace = RuntimeTrace("schema=1;depth=8;count=8;drop=4294967295")
        XCTAssertEqual(trace?.dropped, 4_294_967_295)
    }

    func testTraceMalformedPayloadReturnsNil() {
        XCTAssertNil(RuntimeTrace(""))
        XCTAssertNil(RuntimeTrace("depth=8;count=2|r,s,o"))   // missing schema
    }

    // MARK: - `runtime/twin` (schema v1)

    func testTwinSchemaV1Parsing() {
        // Exact shape from tumoflip_runtime_make_twin_payload's snprintf format.
        let payload = "schema=1;fw=1.4.0000;cm=0d51e938;dy=0;sd=1;pkg=1;"
            + "bat=87;chg=1;otg=0;heap=123456;rf=0;"
            + "ro=;sid=1234ABCD;bo=iphone__"
        let twin = RuntimeTwin(payload)

        XCTAssertEqual(twin?.schema, 1)
        XCTAssertEqual(twin?.firmwareVersion, "1.4.0000")
        XCTAssertEqual(twin?.commit, "0d51e938")
        XCTAssertEqual(twin?.dirty, false)
        XCTAssertEqual(twin?.sdReady, true)
        XCTAssertEqual(twin?.packageStatePresent, true)
        XCTAssertEqual(twin?.batteryPercent, 87)
        XCTAssertEqual(twin?.charging, true)
        XCTAssertEqual(twin?.otgEnabled, false)
        XCTAssertEqual(twin?.maxHeapBlock, 123456)
        XCTAssertEqual(twin?.radioState, 0)
        XCTAssertEqual(twin?.radioStateLabel, "Idle")
        XCTAssertEqual(twin?.sessionID, "1234ABCD")
        XCTAssertEqual(twin?.bridgeOwner, "iphone__")
    }

    func testTwinWithoutRestoredDiagnosticsKeepsLegacyCompatibility() {
        let twin = RuntimeTwin("schema=1;fw=1.4.0000;cm=0d51e938;dy=0;sd=1;pkg=1;bat=87;rf=0;ro=;sid=1234ABCD;bo=iphone__")
        XCTAssertEqual(twin?.batteryPercent, 87)
        XCTAssertNil(twin?.charging)
        XCTAssertNil(twin?.otgEnabled)
        XCTAssertNil(twin?.maxHeapBlock)
    }

    func testTwinHeapAtUInt32Max() {
        // `heap` is %lu (uint32); firmware's own test uses 4294967295 as the vector.
        let twin = RuntimeTwin("schema=1;fw=1.4.0000;cm=0d51e938;dy=1;sd=1;pkg=1;"
            + "bat=100;chg=1;otg=1;heap=4294967295;rf=255;ro=1234;sid=FFFFFFFF;bo=12345678")
        XCTAssertEqual(twin?.maxHeapBlock, 4_294_967_295)
        XCTAssertEqual(twin?.charging, true)
        XCTAssertEqual(twin?.otgEnabled, true)
    }

    func testTwinMalformedPayloadReturnsNil() {
        XCTAssertNil(RuntimeTwin(""))
        XCTAssertNil(RuntimeTwin("fw=1.0;cm=abcd1234"))   // missing schema
    }

    // MARK: - Transfer reporter capability gate
    //
    // TransferActivityReporter.send() now gates entirely on
    // `RuntimeCapabilities(ble.appBridgeCapabilities).supportsTransferActivity` (see
    // TransferActivityReporter.swift) — a pure function of the capabilities dict,
    // fully exercised above. FlipperBLE itself is a hardware-backed singleton with a
    // private initializer (by design — it owns the live CoreBluetooth session), so it
    // isn't constructible here; the capability-parsing tests above are what actually
    // prove "no transfer command is sent without an explicit capability" for both the
    // compact and legacy contracts.
    func testTransferActivityGateMatchesCapabilityParsing() {
        XCTAssertTrue(RuntimeCapabilities(["feat": "pkg,radio,trace,twin,transfer"]).supportsTransferActivity)
        XCTAssertFalse(RuntimeCapabilities(["feat": "pkg,radio,trace,twin"]).supportsTransferActivity)
        XCTAssertTrue(RuntimeCapabilities(["features": "transfer_activity,pkg_state"]).supportsTransferActivity)
        XCTAssertFalse(RuntimeCapabilities(["features": "pkg_state,radio_v2"]).supportsTransferActivity)
    }
}
