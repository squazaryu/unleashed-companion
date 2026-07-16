import XCTest
@testable import UnleashedCompanion

/// Tests for ESP32 Marauder image-name parsing — the version/board-key extraction
/// that matches a local manual-flash folder to a GitHub release asset. Regression
/// cover for the esp32-c5 board, whose filename places the 0x10000 offset before the
/// board name and whose release asset carries a build date.
final class ESP32UpdaterTests: XCTestCase {

    private func parse(_ name: String) -> (version: String, key: String)? {
        ESP32Updater.parseImageName(name)
    }

    func testReleaseAssetNames() {
        // Real justcallmekoko/ESP32Marauder v1.12.2 asset names (version + date + board).
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin")?.key, "esp32c5devkitc1")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_v6_1.bin")?.key, "v6_1")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_marauder_v7.bin")?.key, "marauder_v7")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_cyd_2432S028.bin")?.key, "cyd_2432S028")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_flipper.bin")?.version, "v1.12.2")
    }

    func testLocalManualFolderNames() {
        // Module One style: version + board + offset, no date.
        let moduleOne = parse("esp32_marauder_v1_12_1_v6_1_0x10000.bin")
        XCTAssertEqual(moduleOne?.version, "v1.12.1")
        XCTAssertEqual(moduleOne?.key, "v6_1")

        // The esp32-c5 bug case: offset BEFORE the board name, ".bin" not a clean suffix.
        // Old parser produced key "0x10000_esp32c5devkitc1.bin"; now it's clean.
        let c5 = parse("esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin")
        XCTAssertEqual(c5?.version, "v1.12.2")
        XCTAssertEqual(c5?.key, "esp32c5devkitc1")
    }

    func testWrittenBackNameRoundTrips() {
        // The name install() writes for a new manual folder must re-parse to the same key.
        let written = "esp32_marauder_v1_12_2_esp32c5devkitc1_0x10000.bin"
        XCTAssertEqual(parse(written)?.key, "esp32c5devkitc1")
        XCTAssertEqual(parse(written)?.version, "v1.12.2")
    }

    func testLocalKeyMatchesReleaseKey() {
        // The whole point: a local board matches its release asset by key.
        let local = parse("esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin")?.key
        let asset = parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin")?.key
        XCTAssertNotNil(local)
        XCTAssertEqual(local, asset)
    }

    func testRejectsNonMarauderNames() {
        XCTAssertNil(parse("bootloader_0x1000.bin"))
        XCTAssertNil(parse("partitions_0x8000.bin"))
        XCTAssertNil(parse("boot_app0_0xe000.bin"))
        XCTAssertNil(parse("esp32_marauder_no_version_here.bin"))
        XCTAssertNil(parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.txt"))
    }

    func testManualFolderDetection() {
        XCTAssertTrue(ESP32Updater.isManualFolder("module_one_v6_1_v1_12_3_manual"))
        XCTAssertFalse(ESP32Updater.isManualFolder("_archive"))
        XCTAssertFalse(ESP32Updater.isManualFolder("module_one_v6_1_v1_12_3"))
    }

    func testFolderNameExtraction() {
        XCTAssertEqual(
            ESP32Updater.folderName(from: "/ext/apps_data/esp_flasher/module_one_v6_1_v1_12_3_manual"),
            "module_one_v6_1_v1_12_3_manual")
        XCTAssertEqual(ESP32Updater.folderName(from: "plain_manual"), "plain_manual")
    }
}
