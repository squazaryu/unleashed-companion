import XCTest
@testable import UnleashedCompanion

/// Tests for the Home Assistant Bonjour discovery helpers and the Relay base-URL
/// resolution priority (issue #2). Pure logic only — no NetService / network.
final class HomeAssistantDiscoveryTests: XCTestCase {

    private func txt(_ pairs: [String: String]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, Data($0.value.utf8)) })
    }

    // MARK: - HABonjour.scheme

    func testSchemeDefaultsToHTTP() {
        XCTAssertEqual(HABonjour.scheme(fromTXT: [:]), "http")
        XCTAssertEqual(HABonjour.scheme(fromTXT: txt(["version": "2026.7", "uuid": "abc"])), "http")
    }

    func testSchemeReadsHTTPSFromInternalURL() {
        XCTAssertEqual(HABonjour.scheme(fromTXT: txt(["internal_url": "https://ha.local:8123"])), "https")
    }

    func testSchemeReadsHTTPSFromBaseOrExternalURL() {
        XCTAssertEqual(HABonjour.scheme(fromTXT: txt(["base_url": "https://ha.example.com"])), "https")
        XCTAssertEqual(HABonjour.scheme(fromTXT: txt(["external_url": "HTTPS://ha.example.com"])), "https")
    }

    func testSchemePlainHTTPURLStaysHTTP() {
        XCTAssertEqual(HABonjour.scheme(fromTXT: txt(["base_url": "http://192.168.1.14:8123"])), "http")
    }

    // MARK: - HABonjour.base

    func testBaseStripsTrailingMDNSDot() {
        XCTAssertEqual(HABonjour.base(host: "homeassistant.local.", port: 8123, txt: [:]),
                       "http://homeassistant.local:8123")
    }

    func testBaseUsesResolvedHostNotTXTURL() {
        // TXT may carry a stale/pinned IP; we must build from the resolved host:port
        // (which tracks DHCP) and only borrow the scheme from TXT.
        let base = HABonjour.base(host: "homeassistant.local.", port: 8123,
                                  txt: txt(["internal_url": "https://192.168.1.99:8123"]))
        XCTAssertEqual(base, "https://homeassistant.local:8123")
    }

    func testBaseRejectsEmptyHostOrBadPort() {
        XCTAssertNil(HABonjour.base(host: "", port: 8123, txt: [:]))
        XCTAssertNil(HABonjour.base(host: ".", port: 8123, txt: [:]))     // becomes empty after dot strip
        XCTAssertNil(HABonjour.base(host: "ha.local", port: 0, txt: [:]))
        XCTAssertNil(HABonjour.base(host: "ha.local", port: -1, txt: [:]))
    }

    // MARK: - RelayExecutor.resolveBase priority

    func testResolvePrefersPinnedURL() {
        XCTAssertEqual(
            RelayExecutor.resolveBase(typed: "http://192.168.1.5:8123", discovered: "http://ha.local:8123"),
            "http://192.168.1.5:8123")
    }

    func testResolveFallsBackToDiscoveredWhenEmpty() {
        XCTAssertEqual(
            RelayExecutor.resolveBase(typed: "   ", discovered: "http://ha.local:8123"),
            "http://ha.local:8123")
    }

    func testResolveFallsBackToMDNSNameWhenNothingKnown() {
        XCTAssertEqual(RelayExecutor.resolveBase(typed: "", discovered: nil),
                       "http://homeassistant.local:8123")
        XCTAssertEqual(RelayExecutor.resolveBase(typed: "", discovered: "  "),
                       "http://homeassistant.local:8123")
    }

    func testResolveTrimsWhitespaceAroundValues() {
        XCTAssertEqual(RelayExecutor.resolveBase(typed: "  http://pinned:8123 ", discovered: nil),
                       "http://pinned:8123")
        XCTAssertEqual(RelayExecutor.resolveBase(typed: "", discovered: "  http://found:8123 "),
                       "http://found:8123")
    }
}
