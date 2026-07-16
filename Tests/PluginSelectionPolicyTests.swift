import XCTest
@testable import UnleashedCompanion

final class PluginSelectionPolicyTests: XCTestCase {
    private func update(
        _ path: String,
        selected: Bool = true,
        oldMD5: String? = "old"
    ) -> PluginUpdate {
        var value = PluginUpdate(
            remotePath: path,
            name: (path as NSString).lastPathComponent,
            category: "Tools",
            pack: "base",
            newMD5: "new",
            oldMD5: oldMD5,
            size: 10)
        value.selected = selected
        return value
    }

    private let good = FapMetadata(apiMajor: 88, apiMinor: 4, hardwareTarget: 7)
    private let old = FapMetadata(apiMajor: 87, apiMinor: 15, hardwareTarget: 7)

    func testFullCatalogClassifiesInitiallyUnselectedAndProtectedEntries() {
        let catalog: [String: PluginCatalogMetadata] = [
            "/ext/apps/Tools/good.fap": .parsed(good),
            "/ext/apps/Tools/new-unselected.fap": .parsed(good),
            "/ext/apps/ARF/protected.fap": .parsed(old),
        ]

        let result = PluginSelectionPolicy.classify(
            catalog, deviceApiMajor: 88, deviceTarget: 7)

        XCTAssertEqual(result.count, catalog.count)
        XCTAssertTrue(result["/ext/apps/Tools/good.fap"]?.isInstallable == true)
        XCTAssertTrue(result["/ext/apps/Tools/new-unselected.fap"]?.isInstallable == true)
        guard case let .incompatible(reason)? = result["/ext/apps/ARF/protected.fap"] else {
            return XCTFail("protected entry must be classified")
        }
        XCTAssertTrue(reason.contains("API 87.15"), reason)
    }

    func testUnknownIdentityMakesEveryBinaryUnvalidated() {
        let result = PluginSelectionPolicy.classify(
            ["a": .parsed(good), "b": .invalid],
            deviceApiMajor: nil,
            deviceTarget: nil)

        XCTAssertEqual(result.count, 2)
        for state in result.values {
            guard case .unvalidated = state else { return XCTFail("expected unvalidated") }
        }
    }

    func testIndividualSelectionCannotEnableIncompatibleItem() {
        var updates = [update("good.fap", selected: false), update("old.fap", selected: false)]
        let classifications: [String: FapCompatibilityState] = [
            "good.fap": .compatible(good),
            "old.fap": .incompatible(reason: "API 87.15"),
        ]

        PluginSelectionPolicy.setSelected(
            true, id: updates[1].id, updates: &updates, classifications: classifications)

        XCTAssertFalse(updates[1].selected)
    }

    func testSelectOnlyAndCategorySelectionSkipBlockedItems() {
        var updates = [
            update("good-update.fap"),
            update("good-new.fap", oldMD5: nil),
            update("old.fap"),
        ]
        let classifications: [String: FapCompatibilityState] = [
            "good-update.fap": .compatible(good),
            "good-new.fap": .compatible(good),
            "old.fap": .incompatible(reason: "API 87.15"),
        ]

        PluginSelectionPolicy.selectOnly(
            where: { _ in true }, updates: &updates, classifications: classifications)
        XCTAssertEqual(updates.filter(\.selected).map(\.remotePath), ["good-update.fap", "good-new.fap"])

        PluginSelectionPolicy.selectOnly(
            where: \.isNew, updates: &updates, classifications: classifications)
        XCTAssertEqual(updates.filter(\.selected).map(\.remotePath), ["good-new.fap"])
        XCTAssertEqual(
            PluginSelectionPolicy.selectedInstallable(
                updates, classifications: classifications).map(\.remotePath),
            ["good-new.fap"])
    }

    func testReconnectDeselectsEntriesRejectedByNewFirmware() {
        var updates = [update("app.fap")]
        let compatible = PluginSelectionPolicy.classify(
            ["app.fap": .parsed(good)], deviceApiMajor: 88, deviceTarget: 7)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: compatible)
        XCTAssertTrue(updates[0].selected)

        let switched = PluginSelectionPolicy.classify(
            ["app.fap": .parsed(good)], deviceApiMajor: 89, deviceTarget: 7)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: switched)
        XCTAssertFalse(updates[0].selected)
    }
}
