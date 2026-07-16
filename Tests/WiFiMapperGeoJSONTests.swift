import XCTest
@testable import UnleashedCompanion

final class WiFiMapperGeoJSONTests: XCTestCase {
    func testParsesCleanExportFeature() throws {
        let data = Data("""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [37.6173, 55.7558, 144.2]
              },
              "properties": {
                "ssid": "Cafe",
                "bssid": "aa:bb:cc:dd:ee:ff",
                "auth": "WPA2",
                "channel": 6,
                "samples": 3,
                "best_rssi": -42,
                "last_rssi": -55,
                "avg_rssi": -49,
                "first_tick_ms": 1200,
                "last_tick_ms": 1800,
                "accuracy": 4.5
              }
            }
          ]
        }
        """.utf8)

        let points = try WiFiMapperGeoJSONParser.parse(data, sourceName: "wifi_clean.geojson")

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].ssid, "Cafe")
        XCTAssertEqual(points[0].bssid, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(points[0].primaryRSSI, -42)
        XCTAssertEqual(points[0].samples, 3)
        XCTAssertEqual(points[0].channel, 6)
        XCTAssertEqual(points[0].latitude, 55.7558, accuracy: 0.0001)
        XCTAssertEqual(points[0].longitude, 37.6173, accuracy: 0.0001)
        XCTAssertEqual(points[0].altitude ?? 0, 144.2, accuracy: 0.0001)
        XCTAssertEqual(points[0].accuracy ?? 0, 4.5, accuracy: 0.0001)
        XCTAssertTrue(points[0].isCleanExport)
    }

    func testParsesRawExportFeature() throws {
        let data = Data("""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": {
                "type": "Point",
                "coordinates": [30.3351, 59.9343]
              },
              "properties": {
                "ssid": "",
                "bssid": "11:22:33:44:55:66",
                "auth": "OPEN",
                "rssi": -72,
                "channel": 11,
                "tick_ms": 2400
              }
            }
          ]
        }
        """.utf8)

        let points = try WiFiMapperGeoJSONParser.parse(data, sourceName: "wifi_raw.geojson")

        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].displaySSID, "<hidden>")
        XCTAssertEqual(points[0].primaryRSSI, -72)
        XCTAssertEqual(points[0].tickMS, 2400)
        XCTAssertFalse(points[0].isCleanExport)
    }

    func testDropsInvalidCoordinates() throws {
        let data = Data("""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": { "type": "Point", "coordinates": [300.0, 95.0] },
              "properties": { "ssid": "bad" }
            }
          ]
        }
        """.utf8)

        let points = try WiFiMapperGeoJSONParser.parse(data)

        XCTAssertTrue(points.isEmpty)
    }

    func testDropsZeroZeroGpsPlaceholder() throws {
        let data = Data("""
        {
          "type": "FeatureCollection",
          "features": [
            {
              "type": "Feature",
              "geometry": { "type": "Point", "coordinates": [0.0, 0.0] },
              "properties": {
                "ssid": "No GPS Fix",
                "bssid": "AA:BB:CC:DD:EE:FF",
                "best_rssi": -50,
                "samples": 1
              }
            }
          ]
        }
        """.utf8)

        let points = try WiFiMapperGeoJSONParser.parse(data)

        XCTAssertTrue(points.isEmpty)
    }

    func testEstimatesAccessPointFromMultipleObservations() throws {
        let points = [
            mapperPoint(id: "a", latitude: 55.75580, longitude: 37.61730, rssi: -72),
            mapperPoint(id: "b", latitude: 55.75590, longitude: 37.61755, rssi: -45),
            mapperPoint(id: "c", latitude: 55.75602, longitude: 37.61765, rssi: -48),
            mapperPoint(id: "d", latitude: 55.75570, longitude: 37.61710, rssi: -82),
        ]

        let estimates = WiFiMapperAPEstimator.estimates(from: points)

        XCTAssertEqual(estimates.count, 1)
        XCTAssertEqual(estimates[0].bssid, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(estimates[0].observationCount, 4)
        XCTAssertEqual(estimates[0].strongestRSSI, -45)
        XCTAssertGreaterThan(estimates[0].coordinate.longitude, 37.61740)
        XCTAssertLessThan(estimates[0].radiusMeters, 80)
        XCTAssertNotEqual(estimates[0].confidence, .low)
    }

    func testEstimatorRequiresSeveralObservationsPerBSSID() throws {
        let points = [
            mapperPoint(id: "a", bssid: "AA:BB:CC:DD:EE:FF", latitude: 55.75580, longitude: 37.61730, rssi: -45),
            mapperPoint(id: "b", bssid: "AA:BB:CC:DD:EE:FF", latitude: 55.75590, longitude: 37.61755, rssi: -50),
            mapperPoint(id: "c", bssid: "11:22:33:44:55:66", latitude: 55.75602, longitude: 37.61765, rssi: -48),
        ]

        let estimates = WiFiMapperAPEstimator.estimates(from: points)

        XCTAssertTrue(estimates.isEmpty)
    }

    func testEstimatorIgnoresPointsWithoutRSSI() throws {
        let points = [
            mapperPoint(id: "a", latitude: 55.75580, longitude: 37.61730, rssi: nil),
            mapperPoint(id: "b", latitude: 55.75590, longitude: 37.61755, rssi: -50),
            mapperPoint(id: "c", latitude: 55.75602, longitude: 37.61765, rssi: -48),
        ]

        let estimates = WiFiMapperAPEstimator.estimates(from: points)

        XCTAssertTrue(estimates.isEmpty)
    }

    private func mapperPoint(
        id: String,
        bssid: String = "AA:BB:CC:DD:EE:FF",
        latitude: Double,
        longitude: Double,
        rssi: Int?
    ) -> WiFiMapperPoint {
        WiFiMapperPoint(
            id: id,
            sourceName: "test.geojson",
            ssid: "Cafe",
            bssid: bssid,
            auth: "WPA2",
            channel: 6,
            rssi: rssi,
            bestRSSI: nil,
            lastRSSI: nil,
            averageRSSI: nil,
            samples: nil,
            tickMS: nil,
            firstTickMS: nil,
            lastTickMS: nil,
            latitude: latitude,
            longitude: longitude,
            altitude: nil,
            accuracy: 5)
    }
}
