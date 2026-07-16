import Foundation

enum TumoVMNFCContract {
    static let aid = Data([0xF0, 0x54, 0x56, 0x4D, 0x01])
    static let marker = Data([0x54, 0x56, 0x4D, 0x21])

    static let select = Data([0x00, 0xA4, 0x04, 0x00, 0x05]) + aid
    static let read = Data([0x00, 0xB0, 0x00, 0x00, 0x04])

    static func update(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 255 else { return nil }
        return Data([0x00, 0xD6, 0x00, 0x00, UInt8(data.count)]) + data
    }

    static func status(sw1: UInt8, sw2: UInt8) -> UInt16 {
        (UInt16(sw1) << 8) | UInt16(sw2)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum TumoCardNFCContract {
    static let counterAID = Data([0xF0, 0x54, 0x43, 0x41, 0x52, 0x44, 0x01])
    static let notesAID = Data([0xF0, 0x54, 0x43, 0x41, 0x52, 0x44, 0x02])
    static let counterMarker = Data([0x66, 0x01, 0xCC])
    static let notesMarker = Data([0x66, 0x02, 0xDD])

    static func select(_ aid: Data) -> Data? {
        guard !aid.isEmpty, aid.count <= 16 else { return nil }
        return Data([0x00, 0xA4, 0x04, 0x00, UInt8(aid.count)]) + aid
    }

    static func read(length: Int) -> Data? {
        guard (1...255).contains(length) else { return nil }
        return Data([0x00, 0xB0, 0x00, 0x00, UInt8(length)])
    }

    static func update(offset: Int, data: Data) -> Data? {
        guard (0...0xFFFF).contains(offset), !data.isEmpty, data.count <= 255 else {
            return nil
        }
        return Data([
            0x00,
            0xD6,
            UInt8((offset >> 8) & 0xFF),
            UInt8(offset & 0xFF),
            UInt8(data.count),
        ]) + data
    }
}
