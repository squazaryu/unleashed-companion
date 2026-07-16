import Foundation

enum TumoNetRoute: UInt8, CaseIterable, Identifiable {
    case inbox = 0
    case rf = 1

    var id: UInt8 { rawValue }
    var title: String { self == .inbox ? "Inbox" : "Radio" }
    var wireName: String { self == .inbox ? "Inbox" : "RF" }
}

struct TumoNetEnvelope: Equatable {
    static let textLimit = 96

    let route: TumoNetRoute
    let sourceID: UInt32
    let messageID: UInt32
    let text: String
}

struct TumoNetCapabilities: Equatable {
    let maxTextBytes: Int
    let routes: Set<String>
    let ingress: Set<String>
    let rfMode: String
}

struct TumoNetStatus: Equatable {
    let active: Bool
    let busy: Bool
    let inboxCount: UInt32
    let duplicateCount: UInt32
    let ingress: String
    let route: String
    let status: String
}

struct TumoNetReceipt: Equatable {
    enum Result: String {
        case delivered
        case duplicate
    }

    let result: Result
    let sourceID: UInt32
    let messageID: UInt32
    let route: String
}

enum TumoNetCodec {
    enum CodecError: Error, LocalizedError, Equatable {
        case invalidEnvelope(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .invalidEnvelope(let reason): return "Invalid message: \(reason)."
            case .malformed(let command): return "Invalid TumoNet \(command) response."
            }
        }
    }

    static func encode(_ envelope: TumoNetEnvelope) throws -> Data {
        let text = Data(envelope.text.utf8)
        guard envelope.sourceID != 0 else { throw CodecError.invalidEnvelope("source ID is zero") }
        guard envelope.messageID != 0 else { throw CodecError.invalidEnvelope("message ID is zero") }
        guard !text.isEmpty else { throw CodecError.invalidEnvelope("message is empty") }
        guard text.count <= TumoNetEnvelope.textLimit else {
            throw CodecError.invalidEnvelope("maximum is \(TumoNetEnvelope.textLimit) UTF-8 bytes")
        }
        guard !envelope.text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CodecError.invalidEnvelope("control characters are not allowed")
        }

        var data = Data([0x54, 0x4E, 0x01, envelope.route.rawValue])
        appendLittleEndian(envelope.sourceID, to: &data)
        appendLittleEndian(envelope.messageID, to: &data)
        data.append(UInt8(text.count))
        data.append(text)
        return data
    }

    static func decodeEnvelope(_ data: Data) throws -> TumoNetEnvelope {
        guard data.count >= 13, data[0] == 0x54, data[1] == 0x4E, data[2] == 1,
              let route = TumoNetRoute(rawValue: data[3]) else {
            throw CodecError.malformed("envelope")
        }
        let source = readLittleEndian(data, offset: 4)
        let message = readLittleEndian(data, offset: 8)
        let count = Int(data[12])
        guard source != 0, message != 0, count > 0, count <= TumoNetEnvelope.textLimit,
              data.count == 13 + count,
              let text = String(data: data.subdata(in: 13..<data.count), encoding: .utf8) else {
            throw CodecError.malformed("envelope")
        }
        return TumoNetEnvelope(route: route, sourceID: source, messageID: message, text: text)
    }

    static func parseCapabilities(_ data: Data) throws -> TumoNetCapabilities {
        guard let fields = decodeFields(data), fields["schema"] == "1",
              let max = fields["max"].flatMap(Int.init), max == TumoNetEnvelope.textLimit,
              let routes = fields["routes"], let ingress = fields["ingress"],
              let rfMode = fields["rf"], rfMode == "local_loopback" else {
            throw CodecError.malformed("capabilities")
        }
        return TumoNetCapabilities(
            maxTextBytes: max,
            routes: Set(routes.split(separator: ",").map(String.init)),
            ingress: Set(ingress.split(separator: ",").map(String.init)),
            rfMode: rfMode)
    }

    static func parseStatus(_ data: Data) throws -> TumoNetStatus {
        guard let fields = decodeFields(data), fields["schema"] == "1",
              let active = parseBool(fields["active"]), let busy = parseBool(fields["busy"]),
              let inbox = fields["inbox"].flatMap(UInt32.init),
              let duplicates = fields["duplicates"].flatMap(UInt32.init),
              let ingress = fields["ingress"], let route = fields["route"],
              let status = fields["status"] else {
            throw CodecError.malformed("status")
        }
        return TumoNetStatus(
            active: active,
            busy: busy,
            inboxCount: inbox,
            duplicateCount: duplicates,
            ingress: ingress,
            route: route,
            status: status)
    }

    static func parseReceipt(_ data: Data) throws -> TumoNetReceipt {
        guard let fields = decodeFields(data), fields["schema"] == "1",
              let resultText = fields["status"], let result = TumoNetReceipt.Result(rawValue: resultText),
              let source = fields["source"].flatMap(parseHex32),
              let message = fields["id"].flatMap(parseHex32),
              let route = fields["route"], source != 0, message != 0 else {
            throw CodecError.malformed("send")
        }
        return TumoNetReceipt(result: result, sourceID: source, messageID: message, route: route)
    }

    static func hex(_ value: UInt32) -> String { String(format: "%08X", value) }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func readLittleEndian(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func parseBool(_ value: String?) -> Bool? {
        switch value {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }

    private static func parseHex32(_ value: String) -> UInt32? {
        guard value.count == 8, value.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(value, radix: 16)
    }

    private static func decodeFields(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        var fields: [String: String] = [:]
        for pair in text.split(separator: ";", omittingEmptySubsequences: false) {
            guard !pair.isEmpty, let separator = pair.firstIndex(of: "=") else { return nil }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            guard !key.isEmpty, !value.isEmpty, fields[key] == nil else { return nil }
            fields[key] = value
        }
        return fields
    }
}

extension FlipperBLE {
    func tumonetCapabilities(timeout: TimeInterval = 5) async throws -> TumoNetCapabilities {
        let data = try await appBridgeRequest(
            appID: "tumonet", command: "capabilities", timeout: timeout)
        return try TumoNetCodec.parseCapabilities(data)
    }

    func tumonetStatus(timeout: TimeInterval = 5) async throws -> TumoNetStatus {
        let data = try await appBridgeRequest(appID: "tumonet", command: "status", timeout: timeout)
        return try TumoNetCodec.parseStatus(data)
    }

    func tumonetSend(_ envelope: TumoNetEnvelope, timeout: TimeInterval = 15) async throws -> TumoNetReceipt {
        let payload = try TumoNetCodec.encode(envelope)
        let data = try await appBridgeRequest(
            appID: "tumonet", command: "send", payload: payload, timeout: timeout)
        return try TumoNetCodec.parseReceipt(data)
    }
}
