import Foundation

/// Encodes / decodes the custom App Bridge frame used by the tumoflip firmware
/// (`ble_glue/services/app_bridge_service.c`). Supports both wire versions:
///
///   FAB1 (legacy, 8-byte header, payload <= 172):
///     [0..3]  magic 'F','A','B','1'
///     [4]     app_id length          (<= 32)
///     [5]     command length         (<= 32)
///     [6..7]  payload length, LE16   (<= 172)
///     [8..]   app_id | command | payload
///
///   FAB2 (16-byte header, payload <= 160 per chunk, request id + chunking):
///     [0..3]   magic 'F','A','B','2'
///     [4]      flags  (0x01 ack, 0x02 response, 0x04 error)
///     [5]      app_id length          (1..32)
///     [6]      command length         (1..32)
///     [7]      chunk index (0-based)
///     [8]      chunk count (1..255)
///     [9]      reserved (0)
///     [10..11] payload length, LE16   (0..160)
    ///     [12..15] request id, LE32 (0 is allowed only for unsolicited events)
///     [16..]   app_id | command | payload
///   Whole frame <= 244 bytes. The firmware accepts both versions.
struct AppBridgeFrame: Equatable {
    static let magicV1: [UInt8] = [0x46, 0x41, 0x42, 0x31] // "FAB1"
    static let magicV2: [UInt8] = [0x46, 0x41, 0x42, 0x32] // "FAB2"
    static let headerLenV1 = 8
    static let headerLenV2 = 16
    static let appIDMax = 32
    static let commandMax = 32
    static let payloadMaxV1 = 172
    static let payloadMaxV2 = 160   // BLE_SVC_APP_BRIDGE_V2_PAYLOAD_LEN_MAX
    static let frameMaxV2 = 244     // whole FAB2 frame (header + id + cmd + payload)

    // FAB2 flag bits
    static let flagAckRequested: UInt8 = 0x01
    static let flagResponse: UInt8 = 0x02
    static let flagError: UInt8 = 0x04
    static let flagsMask: UInt8 = 0x07   // ack | response | error — any other bit is invalid

    let appID: String
    let command: String
    let payload: Data
    // FAB2 metadata (defaults describe a single-chunk FAB1 frame).
    var version: Int = 1
    var flags: UInt8 = 0
    var requestID: UInt32 = 0
    var chunkIndex: UInt8 = 0
    var chunkCount: UInt8 = 1

    var isResponse: Bool { (flags & Self.flagResponse) != 0 }
    var isError: Bool { (flags & Self.flagError) != 0 }

    init(appID: String, command: String, payload: Data = Data()) {
        self.appID = appID
        self.command = command
        self.payload = payload
    }

    // MARK: - FAB1 encode (single frame, legacy)

    func encoded() -> Data? {
        let idBytes = Array(appID.utf8)
        let cmdBytes = Array(command.utf8)
        guard !idBytes.isEmpty, !cmdBytes.isEmpty,
              idBytes.count <= Self.appIDMax,
              cmdBytes.count <= Self.commandMax,
              payload.count <= Self.payloadMaxV1 else { return nil }

        var frame = Data(capacity: Self.headerLenV1 + idBytes.count + cmdBytes.count + payload.count)
        frame.append(contentsOf: Self.magicV1)
        frame.append(UInt8(idBytes.count))
        frame.append(UInt8(cmdBytes.count))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(contentsOf: idBytes)
        frame.append(contentsOf: cmdBytes)
        frame.append(payload)
        return frame
    }

    // MARK: - FAB2 encode (one or more chunk frames)

    /// Build FAB2 frame(s) for this app_id/command/payload, splitting the payload
    /// into <=160-byte chunks. Returns nil if the header fields are out of range.
    static func encodeV2(appID: String, command: String, payload: Data,
                         requestID: UInt32, flags: UInt8 = 0) -> [Data]? {
        let idBytes = Array(appID.utf8)
        let cmdBytes = Array(command.utf8)
        guard !idBytes.isEmpty, !cmdBytes.isEmpty,
              idBytes.count <= appIDMax, cmdBytes.count <= commandMax else { return nil }

        var chunks: [Data] = []
        if payload.isEmpty {
            chunks = [Data()]
        } else {
            var i = 0
            while i < payload.count {
                let end = min(i + payloadMaxV2, payload.count)
                chunks.append(payload.subdata(in: i..<end))
                i = end
            }
        }
        guard chunks.count <= 255 else { return nil }
        let count = UInt8(chunks.count)

        var frames: [Data] = []
        for (idx, chunk) in chunks.enumerated() {
            var f = Data(capacity: headerLenV2 + idBytes.count + cmdBytes.count + chunk.count)
            f.append(contentsOf: magicV2)
            f.append(flags)
            f.append(UInt8(idBytes.count))
            f.append(UInt8(cmdBytes.count))
            f.append(UInt8(idx))
            f.append(count)
            f.append(0) // reserved
            f.append(UInt8(chunk.count & 0xFF))
            f.append(UInt8((chunk.count >> 8) & 0xFF))
            f.append(UInt8(requestID & 0xFF))
            f.append(UInt8((requestID >> 8) & 0xFF))
            f.append(UInt8((requestID >> 16) & 0xFF))
            f.append(UInt8((requestID >> 24) & 0xFF))
            f.append(contentsOf: idBytes)
            f.append(contentsOf: cmdBytes)
            f.append(chunk)
            frames.append(f)
        }
        return frames
    }

    // MARK: - Decode (accepts FAB1 and FAB2)

    init?(decoding data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let magic = Array(bytes[0..<4])

        if magic == Self.magicV2 {
            // Strict FAB2 validation — reject any frame that doesn't exactly match the
            // firmware wire contract, so malformed/garbage data can never enter request
            // reassembly or negotiation.
            guard bytes.count >= Self.headerLenV2, bytes.count <= Self.frameMaxV2 else { return nil }
            let fl = bytes[4]
            let idLen = Int(bytes[5])
            let cmdLen = Int(bytes[6])
            let cIdx = bytes[7]
            let cCount = bytes[8]
            let reserved = bytes[9]
            let payLen = Int(bytes[10]) | (Int(bytes[11]) << 8)
            let reqID = UInt32(bytes[12]) | (UInt32(bytes[13]) << 8) |
                        (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 24)
            guard reserved == 0 else { return nil }                       // reserved must be 0
            guard (fl & ~Self.flagsMask) == 0 else { return nil }         // only known flag bits
            guard reqID != 0 || fl == 0 else { return nil }                // zero id only for events
            guard idLen >= 1, idLen <= Self.appIDMax,
                  cmdLen >= 1, cmdLen <= Self.commandMax else { return nil }   // 1...32 each
            guard payLen <= Self.payloadMaxV2 else { return nil }         // <=160 per frame
            guard cCount >= 1, Int(cIdx) < Int(cCount) else { return nil } // count>=1, index in range
            let total = Self.headerLenV2 + idLen + cmdLen + payLen
            guard bytes.count == total else { return nil }                // exact length, no trailing
            var off = Self.headerLenV2
            guard let id = String(bytes: bytes[off..<off+idLen], encoding: .utf8) else { return nil }  // valid UTF-8
            off += idLen
            guard let cmd = String(bytes: bytes[off..<off+cmdLen], encoding: .utf8) else { return nil }
            off += cmdLen
            let pay = Data(bytes[off..<off+payLen])
            self.init(appID: id, command: cmd, payload: pay)
            self.version = 2
            self.flags = fl
            self.requestID = reqID
            self.chunkIndex = cIdx
            self.chunkCount = cCount
            return
        }

        guard magic == Self.magicV1, bytes.count >= Self.headerLenV1 else { return nil }
        let idLen = Int(bytes[4])
        let cmdLen = Int(bytes[5])
        let payLen = Int(bytes[6]) | (Int(bytes[7]) << 8)
        let total = Self.headerLenV1 + idLen + cmdLen + payLen
        guard bytes.count >= total else { return nil }
        var off = Self.headerLenV1
        let id = String(bytes: bytes[off..<off+idLen], encoding: .utf8) ?? ""
        off += idLen
        let cmd = String(bytes: bytes[off..<off+cmdLen], encoding: .utf8) ?? ""
        off += cmdLen
        let pay = Data(bytes[off..<off+payLen])
        self.init(appID: id, command: cmd, payload: pay)
    }
}
