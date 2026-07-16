import XCTest
@testable import UnleashedCompanion

final class TumoNetTests: XCTestCase {
    func testEnvelopeRoundTripPreservesIdentityAndUTF8() throws {
        let envelope = TumoNetEnvelope(
            route: .rf,
            sourceID: 0x10203040,
            messageID: 0x55667788,
            text: "Hello, TumoNet")
        let encoded = try TumoNetCodec.encode(envelope)

        XCTAssertEqual(encoded.prefix(4), Data([0x54, 0x4E, 0x01, 0x01]))
        XCTAssertEqual(try TumoNetCodec.decodeEnvelope(encoded), envelope)
    }

    func testEnvelopeRejectsEmptyOversizedAndControlText() {
        XCTAssertThrowsError(try TumoNetCodec.encode(.init(
            route: .inbox, sourceID: 1, messageID: 2, text: "")))
        XCTAssertThrowsError(try TumoNetCodec.encode(.init(
            route: .inbox, sourceID: 1, messageID: 2, text: String(repeating: "x", count: 97))))
        XCTAssertThrowsError(try TumoNetCodec.encode(.init(
            route: .inbox, sourceID: 1, messageID: 2, text: "line\nbreak")))
    }

    func testCapabilitiesAndStatusAreStrict() throws {
        let capabilities = try TumoNetCodec.parseCapabilities(Data(
            "schema=1;max=96;routes=inbox,rf;ingress=ble,usb;rf=local_loopback".utf8))
        XCTAssertEqual(capabilities.maxTextBytes, 96)
        XCTAssertEqual(capabilities.routes, ["inbox", "rf"])
        XCTAssertEqual(capabilities.ingress, ["ble", "usb"])

        let status = try TumoNetCodec.parseStatus(Data(
            "schema=1;active=1;busy=0;inbox=3;duplicates=2;ingress=BLE;route=Inbox;status=Delivered".utf8))
        XCTAssertTrue(status.active)
        XCTAssertFalse(status.busy)
        XCTAssertEqual(status.inboxCount, 3)
        XCTAssertEqual(status.duplicateCount, 2)

        XCTAssertThrowsError(try TumoNetCodec.parseStatus(Data(
            "schema=1;active=1;active=0;busy=0;inbox=0;duplicates=0;ingress=BLE;route=Inbox;status=Ready".utf8)))
    }

    func testReceiptRequiresStableIdentity() throws {
        let receipt = try TumoNetCodec.parseReceipt(Data(
            "schema=1;status=duplicate;source=10203040;id=55667788;route=Inbox".utf8))
        XCTAssertEqual(receipt.result, .duplicate)
        XCTAssertEqual(receipt.sourceID, 0x10203040)
        XCTAssertEqual(receipt.messageID, 0x55667788)
    }

    @MainActor
    func testSourceIdentityPersistsAcrossViewModels() {
        let suite = "TumoNetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = TumoNetViewModel(defaults: defaults)
        let second = TumoNetViewModel(defaults: defaults)
        XCTAssertEqual(first.sourceLabel, second.sourceLabel)
        defaults.removePersistentDomain(forName: suite)
    }
}
