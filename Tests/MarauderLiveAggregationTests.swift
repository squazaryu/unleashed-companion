import XCTest
@testable import UnleashedCompanion

/// Validates the exact incremental parse path `LiveMarauderViewModel` relies on (issue
/// #6): each chunk relayed from the Flipper is parsed independently and merged into a
/// running result via `MarauderParseResult.aggregate`, the same way the offline flow
/// combines multiple log files — no new parsing logic, just confirming that path holds
/// up for small, successive chunks (as the live relay sends them) rather than one big text.
final class MarauderLiveAggregationTests: XCTestCase {

    func testIncrementalChunksMatchSingleParse() {
        let full = """
        -75 Ch: 6 AA:BB:CC:DD:EE:01 ESSID: HomeNet 11 04
        -60 Ch: 11 AA:BB:CC:DD:EE:02 ESSID: CoffeeShop 11 04
        -80 Ch: 1 AA:BB:CC:DD:EE:03 ESSID: Guest 11 04
        """
        let chunk1 = "-75 Ch: 6 AA:BB:CC:DD:EE:01 ESSID: HomeNet 11 04"
        let chunk2 = "-60 Ch: 11 AA:BB:CC:DD:EE:02 ESSID: CoffeeShop 11 04\n-80 Ch: 1 AA:BB:CC:DD:EE:03 ESSID: Guest 11 04"

        let oneShot = MarauderLogParser.parse(full)
        let incremental = MarauderParseResult.aggregate([
            MarauderLogParser.parse(chunk1),
            MarauderLogParser.parse(chunk2),
        ])

        XCTAssertEqual(Set(oneShot.aps.map(\.bssid)), Set(incremental.aps.map(\.bssid)))
        XCTAssertEqual(oneShot.aps.count, 3)
        XCTAssertEqual(incremental.aps.count, 3)
        for ap in incremental.aps {
            XCTAssertFalse(ap.ssid.isEmpty, "SSID should survive a single-line chunk parse")
        }
    }

    func testAggregateAcrossManySmallChunksDedupesByBSSID() {
        // Simulates the live relay: the same AP line arriving again in a later batch
        // (Marauder re-announces on every beacon) must not create a duplicate entry.
        let chunks = [
            "-70 Ch: 6 AA:BB:CC:DD:EE:AA ESSID: RepeatNet 11 04",
            "-71 Ch: 6 AA:BB:CC:DD:EE:AA ESSID: RepeatNet 11 04",
            "-69 Ch: 6 AA:BB:CC:DD:EE:AA ESSID: RepeatNet 11 04",
        ]
        let merged = MarauderParseResult.aggregate(chunks.map(MarauderLogParser.parse))
        XCTAssertEqual(merged.aps.count, 1)
        XCTAssertEqual(merged.aps.first?.bssid, "AA:BB:CC:DD:EE:AA")
    }

    func testEmptyChunkDoesNotCrashOrAddNoise() {
        let merged = MarauderParseResult.aggregate([
            MarauderLogParser.parse(""),
            MarauderLogParser.parse("-70 Ch: 6 AA:BB:CC:DD:EE:AA ESSID: Solo 11 04"),
        ])
        XCTAssertEqual(merged.aps.count, 1)
    }
}
