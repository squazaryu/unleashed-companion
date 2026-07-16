import Foundation

enum TumoFabricOperation: String, Equatable {
    case increment = "inc"
    case decrement = "dec"
}

struct TumoFabricCapabilities: Equatable {
    let schema: Int
    let node: String
    let package: String
    let operations: Set<String>
    let resumable: Bool
    let persistence: String
    let trust: String
    let active: Bool
    let owner: String

    init?(_ fields: [String: String]) {
        guard fields["schema"] == "1",
              let schema = fields["schema"].flatMap(Int.init),
              let node = fields["node"],
              let package = fields["pkg"],
              let operations = fields["ops"],
              let persistence = fields["persist"],
              let trust = fields["trust"] else { return nil }
        self.schema = schema
        self.node = node
        self.package = package
        self.operations = Set(operations.split(separator: ",").map(String.init))
        resumable = fields["resume"] == "1"
        self.persistence = persistence
        self.trust = trust

        if let activeText = fields["active"] {
            guard activeText == "0" || activeText == "1" else { return nil }
            active = activeText == "1"
        } else {
            active = false
        }

        let owner = fields["owner"] ?? "none"
        guard !owner.isEmpty, owner.count <= 16,
              owner.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        self.owner = owner
    }

    func allowsAutomaticAttach(hasSavedSession: Bool) -> Bool {
        active && (owner == "flipper" || (owner == "iphone" && hasSavedSession))
    }
}

struct TumoFabricState: Equatable {
    let schema: Int
    let package: String
    let sessionID: UInt32
    let token: UInt32
    let sequence: UInt32
    let value: Int
    let duplicate: Bool
    let persistence: String

    init?(_ fields: [String: String]) {
        guard fields["schema"] == "1",
              fields["pkg"] == "counter",
              let schema = fields["schema"].flatMap(Int.init),
              let sid = TumoFabricCodec.hex32(fields["sid"]),
              let token = TumoFabricCodec.hex32(fields["token"]),
              let sequence = fields["seq"].flatMap(UInt32.init),
              let value = fields["value"].flatMap(Int.init),
              (-999...999).contains(value),
              let duplicateText = fields["dup"],
              duplicateText == "0" || duplicateText == "1",
              let persistence = fields["persist"] else { return nil }
        self.schema = schema
        package = "counter"
        sessionID = sid
        self.token = token
        self.sequence = sequence
        self.value = value
        duplicate = duplicateText == "1"
        self.persistence = persistence
    }
}

enum TumoFabricCodec {
    enum CodecError: Error, Equatable, LocalizedError {
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let command):
                return "The Flipper's \(command) reply didn't match TumoFabric v1."
            }
        }
    }

    static func encode(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ";").utf8)
    }

    static func decode(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for pair in text.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            let key = String(parts[0])
            guard fields[key] == nil else { return nil }
            fields[key] = String(parts[1])
        }
        return fields
    }

    static func hex(_ value: UInt32) -> String { String(format: "%08X", value) }

    static func hex32(_ text: String?) -> UInt32? {
        guard let text, text.count == 8, let value = UInt32(text, radix: 16), value != 0 else {
            return nil
        }
        return value
    }

    static func parseState(_ data: Data, command: String) throws -> TumoFabricState {
        guard let fields = decode(data), let state = TumoFabricState(fields) else {
            throw CodecError.malformed(command)
        }
        return state
    }
}

extension FlipperBLE {
    func fabricCapabilities(timeout: TimeInterval = 5) async throws -> TumoFabricCapabilities {
        let data = try await appBridgeRequest(
            appID: "runtime", command: "fabric_caps", timeout: timeout)
        guard let fields = TumoFabricCodec.decode(data),
              let capabilities = TumoFabricCapabilities(fields) else {
            throw TumoFabricCodec.CodecError.malformed("fabric_caps")
        }
        return capabilities
    }

    func fabricOpen(owner: String, token: UInt32, timeout: TimeInterval = 6) async throws -> TumoFabricState {
        let payload = TumoFabricCodec.encode([
            ("owner", owner),
            ("pkg", "counter"),
            ("token", TumoFabricCodec.hex(token)),
        ])
        let data = try await appBridgeRequest(
            appID: "runtime", command: "fabric_open", payload: payload, timeout: timeout)
        return try TumoFabricCodec.parseState(data, command: "fabric_open")
    }

    func fabricState(sessionID: UInt32, token: UInt32, timeout: TimeInterval = 5) async throws -> TumoFabricState {
        let payload = TumoFabricCodec.encode([
            ("sid", TumoFabricCodec.hex(sessionID)),
            ("token", TumoFabricCodec.hex(token)),
        ])
        let data = try await appBridgeRequest(
            appID: "runtime", command: "fabric_state", payload: payload, timeout: timeout)
        return try TumoFabricCodec.parseState(data, command: "fabric_state")
    }

    func fabricStep(
        sessionID: UInt32,
        token: UInt32,
        sequence: UInt32,
        operation: TumoFabricOperation,
        timeout: TimeInterval = 6
    ) async throws -> TumoFabricState {
        let payload = TumoFabricCodec.encode([
            ("sid", TumoFabricCodec.hex(sessionID)),
            ("token", TumoFabricCodec.hex(token)),
            ("seq", String(sequence)),
            ("op", operation.rawValue),
        ])
        let data = try await appBridgeRequest(
            appID: "runtime", command: "fabric_step", payload: payload, timeout: timeout)
        return try TumoFabricCodec.parseState(data, command: "fabric_step")
    }

    func fabricCancel(sessionID: UInt32, token: UInt32, timeout: TimeInterval = 5) async throws {
        let payload = TumoFabricCodec.encode([
            ("sid", TumoFabricCodec.hex(sessionID)),
            ("token", TumoFabricCodec.hex(token)),
        ])
        let data = try await appBridgeRequest(
            appID: "runtime", command: "fabric_cancel", payload: payload, timeout: timeout)
        guard let fields = TumoFabricCodec.decode(data),
              fields["schema"] == "1", fields["status"] == "cancelled" else {
            throw TumoFabricCodec.CodecError.malformed("fabric_cancel")
        }
    }
}
