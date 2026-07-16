import Foundation
import Combine
import UIKit

/// Background responder for the Flipper's AI Radar refresh button. When the
/// on-device AI Dashboard app sends `ai_dashboard / refresh` over the App Bridge
/// (long-press OK), this fetches the latest snapshot from the Mac bridge and
/// streams it back to the Flipper — Flipper → phone → Mac → phone → Flipper.
/// Lives for the whole app session so it works regardless of the open screen.
@MainActor
final class AIRadarRelay: ObservableObject {
    @Published private(set) var lastStatus = ""

    private let ble: FlipperBLE
    private let storage = FlipperStorage()
    private var cancellable: AnyCancellable?

    init(ble: FlipperBLE = .shared) {
        self.ble = ble
        cancellable = ble.appBridgeIn
            .filter { $0.appID == AIRadarBridgeClient.appID && $0.command == "refresh" }
            .sink { [weak self] _ in Task { await self?.handleRefresh() } }
    }

    func handleRefresh() async {
        // The fetch + multi-frame BLE write-back is longer than Sber's single HTTP
        // fire, so hold a background-task assertion to finish the work when the app
        // was woken from the background by the Flipper's BLE event.
        let bg = UIApplication.shared.beginBackgroundTask(withName: "ai-radar-refresh")
        defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }

        let raw = UserDefaults.standard.string(forKey: "aiRadarBridgeURL") ?? ""
        guard let url = AIRadarBridgeClient.usageURL(from: raw) else {
            lastStatus = "Flipper asked to refresh, but no Mac bridge URL is set."
            return
        }
        do {
            let text = try await AIRadarBridgeClient.fetch(url)
            await AIRadarBridgeClient.pushViaAppBridge(text, ble: ble)
            await AIRadarBridgeClient.persist(text, storage: storage)
            lastStatus = "Refreshed from Mac → Flipper."
        } catch {
            lastStatus = "Couldn't reach the Mac bridge."
        }
    }
}
