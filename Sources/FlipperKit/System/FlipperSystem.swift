import Foundation

/// System-level Flipper queries (device info, battery/power). Both RPCs stream
/// back one key/value pair per frame until `has_next == false`, so we collect
/// the whole set and return it in arrival order.
final class FlipperSystem {
    let rpc: FlipperRPC
    init(rpc: FlipperRPC = .shared) { self.rpc = rpc }

    /// All `device_info` key/value pairs (hardware, firmware, radio stack, …),
    /// in the order the Flipper reports them.
    func deviceInfo() async throws -> [(String, String)] {
        let responses = try await rpc.command(timeout: 30) { main in
            main.content = .systemDeviceInfoRequest(PBSystem_DeviceInfoRequest())
        }
        var out: [(String, String)] = []
        for r in responses {
            if case .systemDeviceInfoResponse(let kv) = r.content, !kv.key.isEmpty {
                out.append((kv.key, kv.value))
            }
        }
        return out
    }

    /// All `power_info` key/value pairs (charge level, voltage, temperature, …).
    func powerInfo() async throws -> [(String, String)] {
        let responses = try await rpc.command(timeout: 30) { main in
            main.content = .systemPowerInfoRequest(PBSystem_PowerInfoRequest())
        }
        var out: [(String, String)] = []
        for r in responses {
            if case .systemPowerInfoResponse(let kv) = r.content, !kv.key.isEmpty {
                out.append((kv.key, kv.value))
            }
        }
        return out
    }
}
