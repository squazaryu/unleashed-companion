import XCTest
@testable import UnleashedCompanion

final class TumoSurveySessionTests: XCTestCase {
    func testSessionMetadataParsesVersionedPayload() throws {
        let data = try XCTUnwrap(
            "schema=1;mode=2;file=survey_20260714.csv;aps=17;obs=42".data(using: .utf8)
        )
        let metadata = try XCTUnwrap(TumoSurveySessionMetadata.parse(data))

        XCTAssertEqual(metadata.schema, 1)
        XCTAssertEqual(metadata.mode, 2)
        XCTAssertEqual(metadata.modeLabel, "Wardrive")
        XCTAssertEqual(metadata.fileName, "survey_20260714.csv")
        XCTAssertEqual(metadata.accessPoints, 17)
        XCTAssertEqual(metadata.observations, 42)
    }

    func testSessionStateDelimitsSuccessiveSurveys() throws {
        let start = try XCTUnwrap("schema=1;mode=0;file=a.csv;aps=0;obs=0".data(using: .utf8))
        let stop = try XCTUnwrap("schema=1;mode=0;file=a.csv;aps=3;obs=9".data(using: .utf8))
        var state = TumoSurveySessionState()

        XCTAssertEqual(state.apply(command: "survey_start", payload: start), .started)
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.apply(command: "live_line", payload: Data()), .data)
        XCTAssertEqual(state.apply(command: "survey_stop", payload: stop), .stopped)
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.metadata?.accessPoints, 3)
        XCTAssertEqual(state.metadata?.observations, 9)
        XCTAssertTrue(TumoSurveySessionState.accepts(command: "live_line"))
        XCTAssertFalse(TumoSurveySessionState.accepts(command: "unrelated"))
    }

    func testSecurityClassificationMatchesFirmwareBuckets() {
        XCTAssertEqual(TumoSurveySecurity.classify("[OPEN]"), .open)
        XCTAssertEqual(TumoSurveySecurity.classify("WEP"), .legacy)
        XCTAssertEqual(TumoSurveySecurity.classify("[WPA2_PSK]"), .wpa2)
        XCTAssertEqual(TumoSurveySecurity.classify("WPA3 SAE"), .wpa3)
        XCTAssertEqual(TumoSurveySecurity.classify(""), .other)
    }

    func testReportContainsSessionSummaryAndNetworkInventory() {
        let result = MarauderParseResult(aps: [
            MarauderAP(
                ssid: "Lab",
                bssid: "AA:BB:CC:DD:EE:FF",
                rssi: -42,
                channel: 6,
                auth: "[WPA2_PSK]"
            )
        ])
        let metadata = TumoSurveySessionMetadata(
            schema: 1,
            mode: 0,
            fileName: "survey.csv",
            accessPoints: 1,
            observations: 3
        )

        let report = TumoSurveyReport.make(result: result, metadata: metadata)

        XCTAssertTrue(report.contains("Session: survey.csv"))
        XCTAssertTrue(report.contains("Networks: 1"))
        XCTAssertTrue(report.contains("Lab | AA:BB:CC:DD:EE:FF | 6 | -42 dBm | WPA2"))
    }
}
