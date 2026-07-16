import Foundation
import Combine
import os

private let clog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "companion")

/// Reliable one-tap bridge to the Flipper-side `flipper_companion.fap`.
///
/// The companion announces `companion/ready` when it launches and replies
/// `companion/ack` after each command. Instead of a fixed delay after launching
/// it, we wait for that ready beacon (pinging to prompt it), eliminating the
/// launch race.
@MainActor
final class CompanionBridge: ObservableObject {
    static let shared = CompanionBridge()
    static let appPath = "/ext/apps/Bluetooth/flipper_companion.fap"

    @Published private(set) var ready = false
    @Published private(set) var lastAck: String?
    @Published private(set) var busy = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        FlipperBLE.shared.appBridgeIn
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in self?.handle(frame) }
            .store(in: &cancellables)
        FlipperBLE.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in if state != .ready { self?.ready = false } }
            .store(in: &cancellables)
    }

    private func handle(_ frame: AppBridgeFrame) {
        guard frame.appID == "companion" else { return }
        switch frame.command {
        case "ready":
            ready = true
            clog.notice("companion ready")
        case "ack":
            lastAck = String(data: frame.payload, encoding: .utf8) ?? ""
            clog.notice("companion ack \(self.lastAck ?? "", privacy: .public)")
        default:
            break
        }
    }

    // MARK: - High-level actions

    func transmitSubGhz(_ path: String) async { await send(appID: "subghz", command: "tx", payload: path) }
    func emulateNFC(_ path: String) async      { await send(appID: "nfc", command: "emulate", payload: path) }
    func emulateRFID(_ path: String) async     { await send(appID: "rfid", command: "emulate", payload: path) }
    func page(_ text: String) async            { await send(appID: "pager", command: "notify", payload: text) }

    /// Ensure the companion app is actually running, then deliver the command.
    /// Verifies liveness with a ping (handles the case where the user closed the
    /// companion on the Flipper) and launches it only if there's no reply.
    func send(appID: String, command: String, payload: String) async {
        guard FlipperBLE.shared.state == .ready else { return }
        busy = true
        defer { busy = false }
        lastAck = nil

        if !(await pingAlive(tries: 2)) {
            await launchCompanionApp()
            // Companion announces ready on launch and answers pings.
            _ = await pingAlive(tries: 12)
        }
        FlipperBLE.shared.sendAppBridge(appID: appID, command: command, payload: Data(payload.utf8))
    }

    /// Ping the companion and wait briefly for its `ready` reply.
    private func pingAlive(tries: Int) async -> Bool {
        ready = false
        for _ in 0..<tries {
            FlipperBLE.shared.sendAppBridge(appID: "companion", command: "ping")
            try? await Task.sleep(nanoseconds: 450_000_000)
            if ready { return true }
        }
        return false
    }

    private func launchCompanionApp() async {
        _ = try? await FlipperRPC.shared.command(timeout: 10) { main in
            main.content = .appStartRequest({
                var r = PBApp_StartRequest()
                r.name = Self.appPath
                r.args = ""
                return r
            }())
        }
    }
}
