import XCTest
@testable import UnleashedCompanion

final class TumoSpectrumReportTests: XCTestCase {
    func testAnnouncementParsesStrictFirmwarePayload() throws {
        let data = try XCTUnwrap(
            "schema=1;file=spectrum_20260714_101112.json;type=SUB RAW;freq=433920000;sim=92"
                .data(using: .utf8)
        )
        let announcement = try TumoSpectrumAnnouncement.parse(data)

        XCTAssertEqual(announcement.schema, 1)
        XCTAssertEqual(announcement.fileName, "spectrum_20260714_101112.json")
        XCTAssertEqual(announcement.path, "/ext/apps_data/signal_workbench/reports/spectrum_20260714_101112.json")
        XCTAssertEqual(announcement.type, "SUB RAW")
        XCTAssertEqual(announcement.frequencyHz, 433_920_000)
        XCTAssertEqual(announcement.similarity, 92)
    }

    func testAnnouncementRejectsTraversalAndDuplicateKeys() throws {
        let traversal = try XCTUnwrap(
            "schema=1;file=../spectrum_20260714_101112.json;type=SUB RAW;freq=1;sim=0"
                .data(using: .utf8)
        )
        let duplicate = try XCTUnwrap(
            "schema=1;file=spectrum_20260714_101112.json;type=SUB RAW;freq=1;sim=0;sim=1"
                .data(using: .utf8)
        )

        XCTAssertThrowsError(try TumoSpectrumAnnouncement.parse(traversal))
        XCTAssertThrowsError(try TumoSpectrumAnnouncement.parse(duplicate))
    }

    func testCaptureSetAnnouncementParsesStrictFirmwarePayload() throws {
        let data = try XCTUnwrap(
            "schema=2;file=set_20260715_101112.json;kind=capture_set;samples=3;stable=91"
                .data(using: .utf8)
        )

        let announcement = try TumoSpectrumAnnouncement.parse(data)

        XCTAssertTrue(announcement.isCaptureSet)
        XCTAssertEqual(announcement.path, "/ext/apps_data/signal_workbench/reports/set_20260715_101112.json")
        XCTAssertEqual(announcement.sampleCount, 3)
        XCTAssertEqual(announcement.stablePercent, 91)
        XCTAssertTrue(TumoSpectrumAnnouncement.isSafeReportFileName("set_20260715_101112.json"))
        XCTAssertFalse(TumoSpectrumAnnouncement.isSafeReportFileName("latest_set.json"))
    }

    func testEventFilterRequiresUnsolicitedFAB2Report() {
        var valid = AppBridgeFrame(
            appID: TumoSpectrumAnnouncement.appID,
            command: TumoSpectrumAnnouncement.command,
            payload: Data()
        )
        valid.version = 2
        XCTAssertTrue(TumoSpectrumAnnouncement.accepts(valid))

        var response = valid
        response.flags = AppBridgeFrame.flagResponse
        XCTAssertFalse(TumoSpectrumAnnouncement.accepts(response))

        let unrelated = AppBridgeFrame(appID: "wifi_mapper", command: "report")
        XCTAssertFalse(TumoSpectrumAnnouncement.accepts(unrelated))
    }

    func testValidReportDecodes() throws {
        let report = try TumoSpectrumReport.decodeValidated(validReportData())

        XCTAssertEqual(report.capture.type, "SUB RAW")
        XCTAssertEqual(report.capture.frequencyHz, 433_920_000)
        XCTAssertEqual(report.capture.histogram, [4, 9, 18, 31, 20, 10, 5, 3])
        XCTAssertEqual(report.comparison?.overallSimilarity, 94)
    }

    func testReportRejectsUnsupportedSchema() {
        let data = validReportData(replacing: "\"schema\":1", with: "\"schema\":2")
        XCTAssertThrowsError(try TumoSpectrumReport.decodeValidated(data)) { error in
            XCTAssertEqual(error as? TumoSpectrumReportError, .unsupportedSchema(2))
        }
    }

    func testReportRejectsInvalidHistogram() {
        let data = validReportData(
            replacing: "[4,9,18,31,20,10,5,3]",
            with: "[4,9,18]"
        )
        XCTAssertThrowsError(try TumoSpectrumReport.decodeValidated(data))
    }

    func testCaptureSetReportDecodesAndDocumentDispatches() throws {
        let data = validCaptureSetData()
        let report = try TumoSpectrumCaptureSetReport.decodeValidated(data)

        XCTAssertEqual(report.device, "Garage gate")
        XCTAssertEqual(report.sampleCount, 3)
        XCTAssertEqual(report.inference.stablePercent, 90)
        XCTAssertEqual(report.inference.clustersUs, [400, 1200, 8000])
        XCTAssertEqual(
            try TumoSpectrumDocument.decodeValidated(data),
            .captureSet(report)
        )
    }

    func testCaptureSetRejectsMismatchedSamplesAndPoints() {
        let samplesMismatch = validCaptureSetData(
            replacing: #""sample_count":3"#,
            with: #""sample_count":4"#
        )
        let pointsMismatch = validCaptureSetData(
            replacing: #""changing_points":1"#,
            with: #""changing_points":2"#
        )

        XCTAssertThrowsError(try TumoSpectrumCaptureSetReport.decodeValidated(samplesMismatch))
        XCTAssertThrowsError(try TumoSpectrumCaptureSetReport.decodeValidated(pointsMismatch))
    }

    func testPhaseBCaptureSetDecodesBitFieldsAndCandidates() throws {
        let report = try TumoSpectrumCaptureSetReport.decodeValidated(validPhaseBCaptureSetData())

        XCTAssertEqual(report.version, "2.1.0")
        XCTAssertEqual(report.inference.bitstream?.bitCount, 24)
        XCTAssertEqual(report.inference.bitstream?.changingBits, 4)
        XCTAssertEqual(report.inference.fields?.count, 4)
        XCTAssertEqual(report.inference.counter?.direction, "incrementing")
        XCTAssertEqual(report.inference.checksum?.candidates, ["xor8"])
    }

    func testPhaseBCaptureSetRejectsInvalidPattern() {
        let invalid = validPhaseBCaptureSetData(
            replacing: #""pattern":"01011010000100**010010**""#,
            with: #""pattern":"01011010000100XX010010**""#
        )

        XCTAssertThrowsError(try TumoSpectrumCaptureSetReport.decodeValidated(invalid))
    }

    private func validReportData(
        replacing target: String? = nil,
        with replacement: String = ""
    ) -> Data {
        var json = #"{"schema":1,"app":"TumoSpectrum","version":"1.0.0","created_at":"2026-07-14T10:11:12","capture":{"type":"SUB RAW","name":"garage.sub","path":"/ext/subghz/garage.sub","protocol":"RAW","preset":"AM650","note":"gate","frequency_hz":433920000,"file_size":2048,"truncated":false,"timings":512,"duration_us":123456,"min_us":100,"avg_us":450,"max_us":1200,"bursts":4,"repeat_score":88,"candidate":"OOK burst","histogram":[4,9,18,31,20,10,5,3]},"compared":{"type":"SUB RAW","name":"garage2.sub","path":"/ext/subghz/garage2.sub","protocol":"RAW","preset":"AM650","note":"","frequency_hz":433920000,"file_size":2100,"truncated":false,"timings":510,"duration_us":124000,"min_us":100,"avg_us":455,"max_us":1210,"bursts":4,"repeat_score":87,"candidate":"OOK burst","histogram":[4,9,18,31,20,10,5,3]},"comparison":{"compatible":true,"likely_same":true,"frequency_delta_hz":0,"pulse_delta":-2,"duration_delta_percent":1,"histogram_similarity":100,"overall_similarity":94}}"#
        if let target { json = json.replacingOccurrences(of: target, with: replacement) }
        return Data(json.utf8)
    }

    private func validCaptureSetData(
        replacing target: String? = nil,
        with replacement: String = ""
    ) -> Data {
        var json = #"{"schema":2,"app":"TumoSpectrum","kind":"capture_set","version":"2.0.0","created_at":"2026-07-15T10:11:12","device":"Garage gate","control":"Open","capture_type":"SUB RAW","sample_count":3,"inference":{"compatible":true,"encoding":"Pulse pairs","replay_class":"Static-like","stable_percent":90,"stable_points":9,"changing_points":1,"aligned_points":10,"frames":6,"clusters_us":[400,1200,8000]},"samples":["gate_1.sub","gate_2.sub","gate_3.sub"]}"#
        if let target { json = json.replacingOccurrences(of: target, with: replacement) }
        return Data(json.utf8)
    }

    private func validPhaseBCaptureSetData(
        replacing target: String? = nil,
        with replacement: String = ""
    ) -> Data {
        var json = #"{"schema":2,"app":"TumoSpectrum","kind":"capture_set","version":"2.1.0","created_at":"2026-07-15T13:14:15","device":"Garage gate","control":"Open","capture_type":"SUB RAW","sample_count":3,"inference":{"compatible":true,"encoding":"Pulse pairs","replay_class":"Changing / unknown","stable_percent":83,"stable_points":40,"changing_points":8,"aligned_points":48,"frames":6,"clusters_us":[400,1200,8000],"bitstream":{"bit_count":24,"reference":"010110100001000001001010","pattern":"01011010000100**010010**","stable_bits":20,"changing_bits":4,"unknown_bits":0},"fields":[{"kind":"stable","start":0,"length":14},{"kind":"changing","start":14,"length":2},{"kind":"stable","start":16,"length":6},{"kind":"changing","start":22,"length":2}],"counter":{"found":true,"direction":"incrementing","start":14,"length":2,"confidence":100},"checksum":{"candidates":["xor8"],"start":16,"length":8,"confidence":100}},"samples":["gate_1.sub","gate_2.sub","gate_3.sub"]}"#
        if let target { json = json.replacingOccurrences(of: target, with: replacement) }
        return Data(json.utf8)
    }
}
