import XCTest
@testable import UnleashedCompanion

/// Tests for the tumoflip schema-v2 manifest model, validation and install-plan
/// path safety (issue #8, correctness core). Hardware-independent.
final class TumoflipManifestTests: XCTestCase {

    private let sha = String(repeating: "a", count: 64)
    private let rid = String(repeating: "b", count: 64)

    /// A faithful schema-v2 manifest mirroring the real release sidecar's keys.
    private func base() -> [String: Any] {
        [
            "schema": 2,
            "release_id": rid,
            "firmware": ["api": "87.14", "name": "tumoflip", "version": "tmwhflpprarf089-021",
                         "target": 7, "radio_address": "0x080D7000"],
            "artifacts": ["firmware.dfu": ["bytes": 872073, "sha256": sha]],
            "packages": [
                "base": [["bytes": 21892, "sha256": sha,
                          "md5": String(repeating: "c", count: 32),
                          "source": "apps/Bluetooth/flipper_companion.fap",
                          "target": "/ext/apps/Bluetooth/flipper_companion.fap"]],
                "arf": [["bytes": 1000, "sha256": sha,
                         "source": "apps/Sub-GHz/arf_car_emulate.fap",
                         "target": "/ext/apps/ARF Tools/arf_car_emulate.fap"]],
                "module_one": [["bytes": 1200, "sha256": sha,
                                "source": "apps/module_one.fap", "target": "/ext/apps/module_one.fap"]],
                "protocol_packs": [["bytes": 7408, "sha256": sha,
                                    "source": "apps_data/subghz/plugins/protocol_chrysler.fal",
                                    "target": "/ext/apps_data/subghz/plugins/protocol_chrysler.fal"]],
            ],
            "cleanup": [["canonical": "/ext/apps/ARF Tools/arf_car_emulate.fap",
                         "legacy": "/ext/apps/ARF Tools/ARF Car Emulate.fap"]],
            "safety": ["dfu_gap_bytes": 8567, "minimum_c2_gap_bytes": 8192,
                       "section_gap_bytes": 8876, "updater_bytes": 119221, "updater_limit_bytes": 131072],
        ]
    }

    private func data(_ d: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: d) }
    private func decode(_ d: [String: Any]) throws -> TumoflipManifest { try TumoflipManifest.decode(data(d)) }

    // MARK: - Decode

    func testDecodeMirrorsRealKeys() throws {
        let m = try decode(base())
        XCTAssertEqual(m.schema, 2)
        XCTAssertEqual(m.releaseId, rid)
        XCTAssertEqual(m.firmware.target, 7)
        XCTAssertEqual(m.firmware.api, "87.14")
        XCTAssertEqual(m.firmware.radioAddress, "0x080D7000")
        // Group dictionary keys must survive intact (not camel-cased).
        XCTAssertNotNil(m.packages["module_one"])
        XCTAssertNotNil(m.packages["protocol_packs"])
        XCTAssertEqual(m.packages["base"]?.first?.target, "/ext/apps/Bluetooth/flipper_companion.fap")
        XCTAssertEqual(m.packages["base"]?.first?.md5, String(repeating: "c", count: 32))
        XCTAssertEqual(m.safety?.updaterLimitBytes, 131072)
        XCTAssertEqual(m.cleanup.first?.legacy, "/ext/apps/ARF Tools/ARF Car Emulate.fap")
    }

    func testValidatePasses() throws {
        XCTAssertNoThrow(try decode(base()).validate())
    }

    // MARK: - Validation failures

    func testRejectsWrongSchema() throws {
        var d = base(); d["schema"] = 1
        XCTAssertThrowsError(try decode(d).validate()) {
            XCTAssertEqual($0 as? TumoflipManifestError, .unsupportedSchema(1))
        }
    }

    func testRejectsWrongTarget() throws {
        var d = base(); d["firmware"] = ["api": "87.14", "name": "x", "version": "y", "target": 5]
        XCTAssertThrowsError(try decode(d).validate()) {
            XCTAssertEqual($0 as? TumoflipManifestError, .wrongTarget(expected: 7, got: 5))
        }
    }

    func testRejectsMissingGroup() throws {
        var d = base()
        var pkgs = d["packages"] as! [String: Any]; pkgs.removeValue(forKey: "protocol_packs")
        d["packages"] = pkgs
        XCTAssertThrowsError(try decode(d).validate()) {
            XCTAssertEqual($0 as? TumoflipManifestError, .missingGroup("protocol_packs"))
        }
    }

    func testRejectsBadSha() throws {
        var d = base()
        d["packages"] = ["base": [["bytes": 1, "sha256": "short", "source": "a", "target": "/ext/a"]],
                         "arf": [], "module_one": [], "protocol_packs": []]
        XCTAssertThrowsError(try decode(d).validate()) {
            guard case .invalidEntry = ($0 as? TumoflipManifestError) else { return XCTFail("\($0)") }
        }
    }

    func testAllowsManifestWithoutMD5() throws {
        var d = base()
        var packages = d["packages"] as! [String: Any]
        var baseFiles = packages["base"] as! [[String: Any]]
        baseFiles[0].removeValue(forKey: "md5")
        packages["base"] = baseFiles
        d["packages"] = packages
        let manifest = try decode(d)
        XCTAssertNil(manifest.packages["base"]?.first?.md5)
        XCTAssertNoThrow(try manifest.validate())
    }

    func testRejectsUppercaseOrMalformedMD5() throws {
        for bad in [String(repeating: "A", count: 32), "short", String(repeating: "g", count: 32)] {
            var d = base()
            d["packages"] = [
                "base": [["bytes": 1, "sha256": sha, "md5": bad,
                          "source": "a", "target": "/ext/a"]],
                "arf": [], "module_one": [], "protocol_packs": [],
            ]
            XCTAssertThrowsError(try decode(d).validate(), bad)
        }
    }

    func testRejectsEmptyReleaseID() throws {
        var d = base(); d["release_id"] = "nothex"
        XCTAssertThrowsError(try decode(d).validate()) {
            XCTAssertEqual($0 as? TumoflipManifestError, .emptyReleaseID)
        }
    }

    // MARK: - Path safety

    func testSanitizeAccepts() throws {
        XCTAssertEqual(try TumoflipInstallPlan.sanitize("/ext/apps/a.fap"), "/ext/apps/a.fap")
        XCTAssertEqual(try TumoflipInstallPlan.sanitize("/ext/apps/ARF Tools/x.fap"), "/ext/apps/ARF Tools/x.fap")
    }

    func testSanitizeRejectsTraversal() {
        for bad in ["/ext/../etc/passwd", "/ext/apps/../../x", "/ext/a/./b", "/ext//double", "/data/x", "ext/x", "/ext/"] {
            XCTAssertThrowsError(try TumoflipInstallPlan.sanitize(bad), bad) {
                guard case .unsafeTarget = ($0 as? TumoflipManifestError) else { return XCTFail("\(bad): \($0)") }
            }
        }
    }

    // MARK: - Install plan

    func testPlanSelectsOnlyChosenGroups() throws {
        let m = try decode(base())
        let plan = try TumoflipInstallPlan.make(manifest: m, groups: ["base", "arf"])
        XCTAssertEqual(plan.releaseId, rid)
        XCTAssertEqual(plan.files.map(\.target),
                       ["/ext/apps/Bluetooth/flipper_companion.fap", "/ext/apps/ARF Tools/arf_car_emulate.fap"])
        // cleanup whose canonical (arf_car_emulate) is installed → included.
        XCTAssertEqual(plan.cleanup.count, 1)
    }

    func testPlanExcludesDeselectedFiles() throws {
        let m = try decode(base())
        // Per-file deselection: keep both groups but drop the base file → only arf remains.
        let plan = try TumoflipInstallPlan.make(
            manifest: m, groups: ["base", "arf"],
            excluding: ["/ext/apps/Bluetooth/flipper_companion.fap"])
        XCTAssertEqual(plan.files.map(\.target), ["/ext/apps/ARF Tools/arf_car_emulate.fap"])
    }

    func testPlanCleanupDroppedWhenCanonicalNotInstalled() throws {
        let m = try decode(base())
        // Select only base → the ARF canonical isn't installed, so its cleanup is skipped.
        let plan = try TumoflipInstallPlan.make(manifest: m, groups: ["base"])
        XCTAssertTrue(plan.cleanup.isEmpty)
    }

    func testPlanRejectsDuplicateTarget() throws {
        var d = base()
        // base and module_one both write the same target.
        d["packages"] = [
            "base": [["bytes": 1, "sha256": sha, "source": "a", "target": "/ext/apps/dup.fap"]],
            "module_one": [["bytes": 1, "sha256": sha, "source": "b", "target": "/ext/apps/dup.fap"]],
            "arf": [], "protocol_packs": [],
        ]
        let m = try decode(d)
        XCTAssertThrowsError(try TumoflipInstallPlan.make(manifest: m, groups: ["base", "module_one"])) {
            XCTAssertEqual($0 as? TumoflipManifestError, .duplicateTarget("/ext/apps/dup.fap"))
        }
    }

    func testPlanRejectsCleanupConflict() throws {
        var d = base()
        // cleanup legacy collides with a file being installed.
        d["cleanup"] = [["canonical": "/ext/apps/Bluetooth/flipper_companion.fap",
                         "legacy": "/ext/apps/Bluetooth/flipper_companion.fap"]]
        let m = try decode(d)
        XCTAssertThrowsError(try TumoflipInstallPlan.make(manifest: m, groups: ["base"])) {
            XCTAssertEqual($0 as? TumoflipManifestError,
                           .conflictingCleanup("/ext/apps/Bluetooth/flipper_companion.fap"))
        }
    }
}
