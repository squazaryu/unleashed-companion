import XCTest
@testable import UnleashedCompanion

final class ProtocolTests: XCTestCase {

    // MARK: App Bridge (FAB1) frame

    func testAppBridgeRoundTrip() {
        let frame = AppBridgeFrame(appID: "ai_dashboard", command: "data", payload: Data([1, 2, 3, 250]))
        let encoded = frame.encoded()
        XCTAssertNotNil(encoded)
        let decoded = AppBridgeFrame(decoding: encoded!)
        XCTAssertEqual(decoded?.appID, "ai_dashboard")
        XCTAssertEqual(decoded?.command, "data")
        XCTAssertEqual(decoded?.payload, Data([1, 2, 3, 250]))
    }

    func testAppBridgePayloadLimit() {
        XCTAssertNotNil(AppBridgeFrame(appID: "x", command: "y", payload: Data(count: 172)).encoded())
        XCTAssertNil(AppBridgeFrame(appID: "x", command: "y", payload: Data(count: 173)).encoded())
        XCTAssertNil(AppBridgeFrame(appID: "", command: "y", payload: Data()).encoded())  // empty appID
    }

    // MARK: AI Radar snapshot parser (must match the Flipper's own 10-field format)

    func testAIRadarParse() {
        let text = """
        meta|2026-06-18 20:00
        provider|claude|Claude|CL|claude-api|Session|40|Resets in 54m|11|Resets in 6d 0h
        provider|codex|Codex|<>|codex-rpc|5h|55|Resets in 15m|24|Resets in 5d 9h
        """
        let snap = AIRadarParser.parse(text)
        XCTAssertEqual(snap.updatedAt, "2026-06-18 20:00")
        XCTAssertEqual(snap.providers.count, 2)
        let claude = snap.providers[0]
        XCTAssertEqual(claude.id, "claude")
        XCTAssertEqual(claude.short.label, "Session")
        XCTAssertEqual(claude.short.used, 40)
        XCTAssertEqual(claude.short.remaining, 60)
        XCTAssertEqual(claude.weekly.label, "Weekly")
        XCTAssertEqual(claude.weekly.used, 11)
    }

    func testAIRadarParseClamp() {
        // Out-of-range / short lines: percent clamps, malformed lines ignored.
        let snap = AIRadarParser.parse("provider|x|X|XX|src|5h|250|r|-5|r2\ngarbage|line")
        XCTAssertEqual(snap.providers.count, 1)
        XCTAssertEqual(snap.providers[0].short.used, 100)   // clamped from 250
        XCTAssertEqual(snap.providers[0].weekly.used, 0)    // clamped from -5
    }

    // MARK: RPC length-delimited varint

    func testReadVarint() {
        XCTAssertEqual(FlipperRPC.readVarint(Data([0x05]))?.0, 5)
        XCTAssertEqual(FlipperRPC.readVarint(Data([0x05]))?.1, 1)        // 1 byte consumed
        XCTAssertEqual(FlipperRPC.readVarint(Data([0xAC, 0x02]))?.0, 300) // multi-byte
        XCTAssertEqual(FlipperRPC.readVarint(Data([0xAC, 0x02]))?.1, 2)
        XCTAssertNil(FlipperRPC.readVarint(Data([0x80])))               // incomplete
        XCTAssertNil(FlipperRPC.readVarint(Data()))                     // empty
    }

    func testRPCCommandGateSerializesConcurrentWork() async throws {
        let gate = RPCCommandGate()
        let probe = RPCConcurrencyProbe()

        async let first: Void = gate.withPermit {
            await probe.enter()
            try await Task.sleep(nanoseconds: 80_000_000)
            await probe.leave()
        }
        async let second: Void = gate.withPermit {
            await probe.enter()
            try await Task.sleep(nanoseconds: 10_000_000)
            await probe.leave()
        }

        _ = try await (first, second)
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testRPCCommandGateReleasesPermitAfterError() async throws {
        enum Expected: Error { case failure }
        let gate = RPCCommandGate()

        do {
            _ = try await gate.withPermit { throw Expected.failure }
            XCTFail("Expected the operation to throw")
        } catch Expected.failure {
            // Expected. A following command must still be able to acquire the gate.
        }

        let value = try await gate.withPermit { 42 }
        XCTAssertEqual(value, 42)
    }

    func testContinuousCommandInterruptionHasActionableMessage() {
        let error = FlipperRPCError.status(.errorContinuousCommandInterrupted)
        XCTAssertEqual(
            error.errorDescription,
            "Another Flipper command interrupted the transfer. Wait for the connection to settle, then retry."
        )
    }

    // MARK: Marauder file-format detection

    func testMarauderFormatDetect() {
        // classic pcap, little-endian, DLT 127 (radiotap): magic d4c3b2a1, dlt at [20..23].
        let le: [UInt8] = [0xd4, 0xc3, 0xb2, 0xa1, 2,0,4,0, 0,0,0,0, 0,0,0,0, 0xff,0xff,0,0, 127,0,0,0]
        XCTAssertEqual(MarauderPcap.detectFormat(Data(le)), .classicPcap(dlt: 127))
        // classic pcap, big-endian, DLT 105 (802.11).
        let be: [UInt8] = [0xa1, 0xb2, 0xc3, 0xd4, 0,2,0,4, 0,0,0,0, 0,0,0,0, 0,0,0xff,0xff, 0,0,0,105]
        XCTAssertEqual(MarauderPcap.detectFormat(Data(be)), .classicPcap(dlt: 105))
        // pcapng section-header magic.
        XCTAssertEqual(MarauderPcap.detectFormat(Data([0x0a, 0x0d, 0x0d, 0x0a, 0,0,0,0])), .pcapng)
        // anything else → text.
        XCTAssertEqual(MarauderPcap.detectFormat(Data("0: MyWiFi, -50, 6, AA:BB:CC:DD:EE:FF".utf8)), .text)
        XCTAssertEqual(MarauderPcap.detectFormat(Data()), .text)
    }

    func testMarauderScanAllLog() {
        // The real format saved to /ext/apps_data/marauder/logs/scanall_*.log.
        let log = """
        #scanall
        Scanning for APs and Stations. Stop with stopscan
        > -88 Ch: 11 54:c2:50:cd:f1:51 ESSID: MTS_GPON_cdf150 11 04
        -66 Ch: 36 c8:b6:d3:80:17:84 ESSID: MGTS_GPON5_Rn4n 31 15
        #stopscan
        """
        let r = MarauderLogParser.parse(log)
        XCTAssertEqual(r.aps.count, 2)
        let byBssid = Dictionary(uniqueKeysWithValues: r.aps.map { ($0.bssid, $0) })
        XCTAssertEqual(byBssid["54:C2:50:CD:F1:51"]?.ssid, "MTS_GPON_cdf150")
        XCTAssertEqual(byBssid["54:C2:50:CD:F1:51"]?.channel, 11)
        XCTAssertEqual(byBssid["54:C2:50:CD:F1:51"]?.rssi, -88)
        XCTAssertEqual(byBssid["C8:B6:D3:80:17:84"]?.ssid, "MGTS_GPON5_Rn4n")
    }

    func testMarauderWardriveLog() {
        // Real wardrive rows: "<idx> | <bssid>,<ssid>,<auth>,,<ch>,<rssi>,<lat>,<lon>,<alt>,<acc>,WIFI",
        // the first of a batch prefixed with [BUF/CLOSE]. No "ESSID:"/"Ch:" here.
        let log = """
        [BUF/CLOSE]1 | 74:9D:79:8C:E8:28,MGTS_GPON_4509,[WPA2_PSK],,11,-76,0.0000000,0.0000000,0.00,0.00,WIFI
        2 | 26:A4:3C:E3:CB:EE,,[OPEN],,1,-70,0.0000000,0.0000000,0.00,0.00,WIFI
        3 | 52:FF:20:78:27:D1,52:FF:20:78:27:D1,[WPA2_PSK],,6,-85,0.0000000,0.0000000,0.00,0.00,WIFI
        """
        let r = MarauderLogParser.parse(log)
        XCTAssertEqual(r.aps.count, 3)
        let by = Dictionary(uniqueKeysWithValues: r.aps.map { ($0.bssid, $0) })
        // SSID/channel/rssi/auth all extracted from the wardrive shape.
        XCTAssertEqual(by["74:9D:79:8C:E8:28"]?.ssid, "MGTS_GPON_4509")
        XCTAssertEqual(by["74:9D:79:8C:E8:28"]?.channel, 11)
        XCTAssertEqual(by["74:9D:79:8C:E8:28"]?.rssi, -76)
        XCTAssertEqual(by["74:9D:79:8C:E8:28"]?.auth, "[WPA2_PSK]")
        // Empty SSID and SSID==BSSID both render as hidden (blank), not a MAC fragment.
        XCTAssertEqual(by["26:A4:3C:E3:CB:EE"]?.ssid, "")
        XCTAssertEqual(by["26:A4:3C:E3:CB:EE"]?.auth, "[OPEN]")
        XCTAssertEqual(by["52:FF:20:78:27:D1"]?.ssid, "")
    }

    func testAggregateMergesAcrossFiles() {
        var a = MarauderParseResult()
        a.aps = [MarauderAP(ssid: "Net", bssid: "AA:BB:CC:00:00:01", channel: 6)]
        a.stations = [MarauderStation(mac: "11:22:33:44:55:66", bssid: "AA:BB:CC:00:00:01", packets: 3)]
        var b = MarauderParseResult()
        b.aps = [MarauderAP(ssid: "", bssid: "AA:BB:CC:00:00:01")]                 // same AP, blank ssid
        b.stations = [MarauderStation(mac: "11:22:33:44:55:66", bssid: "AA:BB:CC:00:00:01", packets: 2)]
        b.credentials = [CapturedCredential(username: "u", password: "p", source: "x")]
        let agg = MarauderParseResult.aggregate([a, b])
        XCTAssertEqual(agg.aps.count, 1)               // deduped by BSSID
        XCTAssertEqual(agg.aps[0].ssid, "Net")         // ssid carried over from a
        XCTAssertEqual(agg.aps[0].channel, 6)
        XCTAssertEqual(agg.aps[0].clients, 1)          // one unique associated client
        XCTAssertEqual(agg.stations.count, 1)          // deduped by MAC
        XCTAssertEqual(agg.stations[0].packets, 5)     // packets summed
        XCTAssertEqual(agg.credentials.count, 1)
    }

    func testLogKindClassification() {
        XCTAssertEqual(MarauderLogKind.of("sniffbeacon_4.pcap"), .capture)
        XCTAssertEqual(MarauderLogKind.of("scanall_2.log"), .scan)
        XCTAssertEqual(MarauderLogKind.of("wardrive_1.txt"), .scan)
        XCTAssertEqual(MarauderLogKind.of("evilportal_0.txt"), .portal)
        XCTAssertEqual(MarauderLogKind.of("info_1.log"), .other)
        XCTAssertEqual(MarauderLogKind.of("help_0.log"), .other)
    }
}

private actor RPCConcurrencyProbe {
    private var active = 0
    private(set) var maxActive = 0

    func enter() {
        active += 1
        maxActive = max(maxActive, active)
    }

    func leave() {
        active -= 1
    }
}
