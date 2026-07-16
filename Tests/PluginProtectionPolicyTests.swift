import XCTest
@testable import UnleashedCompanion

final class PluginProtectionPolicyTests: XCTestCase {
    func testArchiveRoutingIncludesAppsAndAppsDataBinaries() {
        XCTAssertEqual(
            PluginInstallRouting.remotePath(
                for: "base_pack_build/artifacts-base/Tools/totp.fap"),
            "/ext/apps/Tools/totp.fap")
        XCTAssertEqual(
            PluginInstallRouting.remotePath(
                for: "base_pack_build/apps_data/totp/plugins/totp_cli_add_plugin.fal"),
            "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal")
        XCTAssertNil(PluginInstallRouting.remotePath(for: "base_pack_build/README.md"))
    }

    func testDependentTotpFalIsProtectedByOwningApp() {
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "totp_cli_add_plugin",
            remotePath: "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal",
            excluded: ["totp"],
            unprotectedBuiltIns: []))
    }

    func testSubGhzProtocolFamilyIsProtectedAsOneUnit() {
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "protocol_vag",
            remotePath: "/ext/apps_data/subghz/plugins/protocol_vag.fal",
            excluded: ["subghz_protocols"],
            unprotectedBuiltIns: []))
    }

    func testUnprotectingOwnerLiftsDependentFalProtection() {
        XCTAssertFalse(PluginProtectionPolicy.isProtected(
            name: "totp_cli_add_plugin",
            remotePath: "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal",
            excluded: ["totp"],
            unprotectedBuiltIns: ["totp"]))
    }

    func testBuiltInListCoversTumoflipAppsAndRetiresBleKiller() {
        let expected: Set<String> = [
            "ai_dashboard", "app_bridge_terminal", "arf_frequency_analyzer",
            "arf_subghz_full", "ble_gatt_lab", "claude_buddy", "esp32_wifi_marauder",
            "field_logger", "flipper_companion", "flipper_relay",
            "module_one_cockpit", "module_one_sensor_logger", "nfc_ccid_bridge",
            "protocol_compiler", "proto_pirate",
            "quac", "rolljam", "runtime_trace_viewer", "signal_workbench",
            "subghz_bruteforcer", "subghz_protocols", "subghz_raw_edit", "totp",
            "tumo_acceptance_suite", "tumo_ir_lab", "tumo_macro_deck", "tumocard_os",
            "tumofabric_node", "tumoflip_packages", "tumoflip_xremote",
            "tumokey_phase_a", "tumomodule_runtime", "tumonet_bench", "tumonet_gateway",
            "tumoscope", "tumoscript", "tumovgm_bridge", "tumovm_peripherals",
            "tumovm_poc", "usb_sd_mode",
            "wifi_mapper",
        ]

        XCTAssertTrue(expected.isSubset(of: PluginUpdater.builtInExcluded))
        XCTAssertFalse(PluginUpdater.builtInExcluded.contains("ble_killer"))
    }

    func testCatalogCannotOverwriteProtectedClaudeBuddy() {
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "claude_buddy"))
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "claude_buddy.fap"))
        XCTAssertNil(CatalogInstallPolicy.protectionReason(alias: "weather_station"))
    }
}
