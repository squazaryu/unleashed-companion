import XCTest
@testable import UnleashedCompanion

/// Tests for the unified App Bridge Console contract (issues #16 + #17): the
/// `key=value;…` payload codec, the per-command payload rules (owner/sid/text),
/// session gating, and hello-response sid extraction. Pure logic — no BLE.
final class AppBridgeConsoleTests: XCTestCase {

    private func str(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

    // MARK: - Params codec

    func testParamsEncodePreservesOrder() {
        XCTAssertEqual(str(AppBridgeParams.encode([("owner", "iphone")])), "owner=iphone")
        XCTAssertEqual(str(AppBridgeParams.encode([("sid", "1a2b"), ("text", "hi")])), "sid=1a2b;text=hi")
    }

    func testParamsEncodeEmptyIsEmpty() {
        XCTAssertEqual(str(AppBridgeParams.encode([])), "")
    }

    func testParamsDecodeRoundTrips() {
        let d = AppBridgeParams.encode([("sid", "ff00"), ("text", "test")])
        let m = AppBridgeParams.decode(d)
        XCTAssertEqual(m["sid"], "ff00")
        XCTAssertEqual(m["text"], "test")
    }

    func testParamsDecodeToleratesGarbageAndWhitespace() {
        let m = AppBridgeParams.decode(Data("  sid = ab ;garbage; =novalue;text=ok ".utf8))
        XCTAssertEqual(m["sid"], "ab")
        XCTAssertEqual(m["text"], "ok")
        XCTAssertNil(m["garbage"])          // no '=' → skipped
        XCTAssertNil(m[""])                 // empty key → skipped
    }

    // MARK: - Payload rules

    func testHelloCarriesOwner() {
        let p = AppBridgeConsoleContract.payload(target: .terminal, command: "hello", sid: nil, text: "x")
        XCTAssertEqual(str(p), "owner=iphone")
    }

    func testTerminalEchoInjectsSidAndText() {
        let p = AppBridgeConsoleContract.payload(target: .terminal, command: "echo", sid: "1a2b", text: "test")
        XCTAssertEqual(str(p), "sid=1a2b;text=test")
    }

    func testTerminalEmitInjectsSidAndText() {
        let p = AppBridgeConsoleContract.payload(target: .terminal, command: "emit", sid: "beef", text: "go")
        XCTAssertEqual(str(p), "sid=beef;text=go")
    }

    func testTerminalReleaseCarriesOnlySid() {
        let p = AppBridgeConsoleContract.payload(target: .terminal, command: "release", sid: "beef", text: "ignored")
        XCTAssertEqual(str(p), "sid=beef")
    }

    func testTerminalPingStatusHelpHaveEmptyPayload() {
        for cmd in ["ping", "status", "help"] {
            XCTAssertEqual(str(AppBridgeConsoleContract.payload(
                target: .terminal, command: cmd, sid: "beef", text: "x")), "",
                "\(cmd) must carry no payload")
        }
    }

    func testGattLabEchoHasTextButNeverSid() {
        // GATT Lab is sessionless: even if a sid is passed, it must not appear.
        let p = AppBridgeConsoleContract.payload(target: .gattLab, command: "echo", sid: "1a2b", text: "test")
        XCTAssertEqual(str(p), "text=test")
    }

    func testGattLabPingEmpty() {
        XCTAssertEqual(str(AppBridgeConsoleContract.payload(
            target: .gattLab, command: "ping", sid: nil, text: "x")), "")
    }

    // MARK: - Session gating

    func testRequiresSessionMatrix() {
        XCTAssertTrue(AppBridgeConsoleContract.requiresSession(.terminal, "echo"))
        XCTAssertTrue(AppBridgeConsoleContract.requiresSession(.terminal, "emit"))
        XCTAssertTrue(AppBridgeConsoleContract.requiresSession(.terminal, "release"))
        XCTAssertFalse(AppBridgeConsoleContract.requiresSession(.terminal, "ping"))
        XCTAssertFalse(AppBridgeConsoleContract.requiresSession(.terminal, "status"))
        XCTAssertFalse(AppBridgeConsoleContract.requiresSession(.terminal, "hello"))
        // GATT Lab is sessionless — nothing requires a sid.
        for cmd in ["ping", "status", "echo"] {
            XCTAssertFalse(AppBridgeConsoleContract.requiresSession(.gattLab, cmd))
        }
    }

    // MARK: - hello response → sid

    func testSessionIDExtraction() {
        XCTAssertEqual(AppBridgeConsoleContract.sessionID(from: Data("sid=1a2b3c;bo=iphone".utf8)), "1a2b3c")
        XCTAssertNil(AppBridgeConsoleContract.sessionID(from: Data("bo=iphone".utf8)))   // no sid
        XCTAssertNil(AppBridgeConsoleContract.sessionID(from: Data("sid=".utf8)))        // empty sid
        XCTAssertNil(AppBridgeConsoleContract.sessionID(from: Data()))                   // empty payload
    }

    // MARK: - Target metadata

    func testTargetCommandSets() {
        XCTAssertEqual(AppBridgeTarget.terminal.commands,
                       ["hello", "ping", "status", "help", "echo", "emit", "release"])
        XCTAssertEqual(AppBridgeTarget.gattLab.commands, ["ping", "status", "echo"])
    }

    func testTargetSessionFlag() {
        XCTAssertTrue(AppBridgeTarget.terminal.usesSession)
        XCTAssertFalse(AppBridgeTarget.gattLab.usesSession)
    }

    func testTargetRawValuesMatchFirmwareAppIDs() {
        XCTAssertEqual(AppBridgeTarget.terminal.rawValue, "app_bridge_terminal")
        XCTAssertEqual(AppBridgeTarget.gattLab.rawValue, "ble_gatt_lab")
    }
}
