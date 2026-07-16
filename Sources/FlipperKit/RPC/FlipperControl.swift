import Foundation
import Combine

/// High-level Flipper actions: launch apps/.fap, send Sub-GHz files, remote
/// input, device info, and the screen stream decoder.
final class FlipperControl: ObservableObject {
    let rpc: FlipperRPC
    private var streamCancellable: AnyCancellable?

    /// Latest decoded screen frame as a 128x64 1-bpp bitmap, expanded to bytes.
    @Published var screenPixels: [Bool] = Array(repeating: false, count: 128 * 64)
    @Published var streaming = false

    static let screenW = 128
    static let screenH = 64

    init(rpc: FlipperRPC = .shared) {
        self.rpc = rpc
        streamCancellable = rpc.unsolicited.sink { [weak self] main in
            if case .guiScreenFrame(let frame) = main.content {
                self?.decodeScreen(frame.data)
            }
        }
    }

    // MARK: - Apps / .fap

    /// Launch an installed app or .fap by name or full path (e.g. "Sub-GHz" or
    /// "/ext/apps/Tools/marauder.fap"), optionally passing a file argument.
    func startApp(_ nameOrPath: String, args: String = "") async throws {
        _ = try await rpc.command { main in
            main.content = .appStartRequest({
                var r = PBApp_StartRequest()
                r.name = nameOrPath
                r.args = args
                return r
            }())
        }
    }

    /// Open a saved Sub-GHz file on the Flipper (launches the stock Sub-GHz app
    /// with the file loaded, ready to transmit on-device).
    func openSubGhzFile(_ path: String) async throws {
        try await startApp("Sub-GHz", args: path)
    }

    // Sub-GHz transmit / NFC+RFID emulate now go through CompanionBridge (it
    // waits for the companion's `ready` beacon instead of a fixed delay).

    func openNFCFile(_ path: String) async throws { try await startApp("NFC", args: path) }
    func openRFIDFile(_ path: String) async throws { try await startApp("125 kHz RFID", args: path) }

    // MARK: - Remote input (screen mirroring control)

    func startScreenStream() {
        rpc.send { main in
            main.content = .guiStartScreenStreamRequest(PBGui_StartScreenStreamRequest())
        }
        DispatchQueue.main.async { self.streaming = true }
    }

    func stopScreenStream() {
        rpc.send { main in
            main.content = .guiStopScreenStreamRequest(PBGui_StopScreenStreamRequest())
        }
        DispatchQueue.main.async { self.streaming = false }
    }

    func press(_ key: PBGui_InputKey, type: PBGui_InputType = .short) {
        // A short button press is press + short + release in the firmware model.
        // The firmware models a tap as press → (short|long) → release.
        sendInput(key, .press)
        sendInput(key, type == .long ? .long : .short)
        sendInput(key, .release)
    }

    private func sendInput(_ key: PBGui_InputKey, _ type: PBGui_InputType) {
        rpc.send { main in
            main.content = .guiSendInputEventRequest({
                var r = PBGui_SendInputEventRequest()
                r.key = key
                r.type = type
                return r
            }())
        }
    }

    // MARK: - Screen decode (128x64, 1bpp, column-major pages like SSD1306)

    private func decodeScreen(_ data: Data) {
        let w = Self.screenW, h = Self.screenH
        var pixels = Array(repeating: false, count: w * h)
        let bytes = [UInt8](data)
        // Flipper sends 1024 bytes: 8 pages of 128 columns, LSB = top pixel of page.
        for page in 0..<(h / 8) {
            for x in 0..<w {
                let idx = page * w + x
                guard idx < bytes.count else { continue }
                let b = bytes[idx]
                for bit in 0..<8 {
                    let y = page * 8 + bit
                    if (b >> bit) & 1 == 1 { pixels[y * w + x] = true }
                }
            }
        }
        DispatchQueue.main.async { self.screenPixels = pixels }
    }
}
