import XCTest
@testable import UnleashedCompanion

final class TumoFabricTests: XCTestCase {
    func testCapabilitiesContract() {
        let data = Data("schema=1;node=flipper;pkg=counter;ops=inc,dec;resume=1;persist=ram;trust=ble-bond;active=1;owner=flipper".utf8)
        let fields = TumoFabricCodec.decode(data)
        let capabilities = fields.flatMap(TumoFabricCapabilities.init)

        XCTAssertEqual(capabilities?.schema, 1)
        XCTAssertEqual(capabilities?.node, "flipper")
        XCTAssertEqual(capabilities?.package, "counter")
        XCTAssertEqual(capabilities?.operations, ["inc", "dec"])
        XCTAssertEqual(capabilities?.resumable, true)
        XCTAssertEqual(capabilities?.persistence, "ram")
        XCTAssertEqual(capabilities?.trust, "ble-bond")
        XCTAssertEqual(capabilities?.active, true)
        XCTAssertEqual(capabilities?.owner, "flipper")
        XCTAssertEqual(capabilities?.allowsAutomaticAttach(hasSavedSession: false), true)
    }

    func testCapabilitiesDoNotAutoCreateAnIdleSession() {
        let idle = TumoFabricCodec.decode(Data("schema=1;node=flipper;pkg=counter;ops=inc,dec;resume=1;persist=ram;trust=ble-bond;active=0;owner=none".utf8))
            .flatMap(TumoFabricCapabilities.init)
        let foreign = TumoFabricCodec.decode(Data("schema=1;node=flipper;pkg=counter;ops=inc,dec;resume=1;persist=ram;trust=ble-bond;active=1;owner=other".utf8))
            .flatMap(TumoFabricCapabilities.init)
        let resumable = TumoFabricCodec.decode(Data("schema=1;node=flipper;pkg=counter;ops=inc,dec;resume=1;persist=ram;trust=ble-bond;active=1;owner=iphone".utf8))
            .flatMap(TumoFabricCapabilities.init)

        XCTAssertEqual(idle?.allowsAutomaticAttach(hasSavedSession: true), false)
        XCTAssertEqual(foreign?.allowsAutomaticAttach(hasSavedSession: true), false)
        XCTAssertEqual(resumable?.allowsAutomaticAttach(hasSavedSession: false), false)
        XCTAssertEqual(resumable?.allowsAutomaticAttach(hasSavedSession: true), true)
    }

    func testLegacyCapabilitiesRemainManualStartCompatible() {
        let legacy = TumoFabricCodec.decode(Data("schema=1;node=flipper;pkg=counter;ops=inc,dec;resume=1;persist=ram;trust=ble-bond".utf8))
            .flatMap(TumoFabricCapabilities.init)

        XCTAssertEqual(legacy?.active, false)
        XCTAssertEqual(legacy?.owner, "none")
    }

    func testStateContractAndDuplicateMarker() throws {
        let data = Data("schema=1;pkg=counter;sid=1234ABCD;token=89ABCDEF;seq=7;value=-12;dup=1;persist=ram".utf8)
        let state = try TumoFabricCodec.parseState(data, command: "fabric_step")

        XCTAssertEqual(state.sessionID, 0x1234ABCD)
        XCTAssertEqual(state.token, 0x89ABCDEF)
        XCTAssertEqual(state.sequence, 7)
        XCTAssertEqual(state.value, -12)
        XCTAssertTrue(state.duplicate)
    }

    func testStrictDecoderRejectsDuplicatesAndMalformedPairs() {
        XCTAssertNil(TumoFabricCodec.decode(Data("sid=1234ABCD;sid=89ABCDEF".utf8)))
        XCTAssertNil(TumoFabricCodec.decode(Data("sid=".utf8)))
        XCTAssertNil(TumoFabricCodec.decode(Data("sid".utf8)))
        XCTAssertNil(TumoFabricCodec.decode(Data("sid=1234ABCD;".utf8)))
    }

    func testStateRejectsZeroCredentialsAndOutOfRangeValue() {
        XCTAssertThrowsError(try TumoFabricCodec.parseState(
            Data("schema=1;pkg=counter;sid=00000000;token=89ABCDEF;seq=0;value=0;dup=0;persist=ram".utf8),
            command: "fabric_state"))
        XCTAssertThrowsError(try TumoFabricCodec.parseState(
            Data("schema=1;pkg=counter;sid=1234ABCD;token=89ABCDEF;seq=0;value=1000;dup=0;persist=ram".utf8),
            command: "fabric_state"))
    }

    func testPayloadEncodingIsDeterministic() {
        let payload = TumoFabricCodec.encode([
            ("sid", TumoFabricCodec.hex(0x1234ABCD)),
            ("token", TumoFabricCodec.hex(0x89ABCDEF)),
            ("seq", "8"),
            ("op", TumoFabricOperation.increment.rawValue),
        ])
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            "sid=1234ABCD;token=89ABCDEF;seq=8;op=inc")
    }

    @MainActor
    func testSavedSessionIsRecognized() {
        let suite = "TumoFabricTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("1234ABCD", forKey: "tumofabric.counter.sid")
        defaults.set("89ABCDEF", forKey: "tumofabric.counter.token")
        let model = TumoFabricViewModel(defaults: defaults)
        XCTAssertTrue(model.hasSavedSession)
        defaults.removePersistentDomain(forName: suite)
    }
}
