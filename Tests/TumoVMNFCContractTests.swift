import XCTest
@testable import UnleashedCompanion

final class TumoVMNFCContractTests: XCTestCase {
    func testAPDUContractMatchesFirmware() {
        XCTAssertEqual(TumoVMNFCContract.select, Data([0x00, 0xA4, 0x04, 0x00, 0x05, 0xF0, 0x54, 0x56, 0x4D, 0x01]))
        XCTAssertEqual(TumoVMNFCContract.read, Data([0x00, 0xB0, 0x00, 0x00, 0x04]))
        XCTAssertEqual(
            TumoVMNFCContract.update(Data([0xAA, 0xBB])),
            Data([0x00, 0xD6, 0x00, 0x00, 0x02, 0xAA, 0xBB])
        )
    }

    func testUpdateRejectsUnsupportedLengths() {
        XCTAssertNil(TumoVMNFCContract.update(Data()))
        XCTAssertNil(TumoVMNFCContract.update(Data(repeating: 0, count: 256)))
    }

    func testStatusAndHexFormatting() {
        XCTAssertEqual(TumoVMNFCContract.status(sw1: 0x90, sw2: 0x00), 0x9000)
        XCTAssertEqual(TumoVMNFCContract.hex(Data([0x0A, 0xFF, 0x01])), "0A FF 01")
    }

    func testTumoCardContractMatchesFirmware() {
        XCTAssertEqual(
            TumoCardNFCContract.select(TumoCardNFCContract.counterAID),
            Data([0x00, 0xA4, 0x04, 0x00, 0x07, 0xF0, 0x54, 0x43, 0x41, 0x52, 0x44, 0x01])
        )
        XCTAssertEqual(
            TumoCardNFCContract.read(length: 16),
            Data([0x00, 0xB0, 0x00, 0x00, 0x10])
        )
        XCTAssertEqual(
            TumoCardNFCContract.update(offset: 13, data: Data([0x66, 0x02, 0xDD])),
            Data([0x00, 0xD6, 0x00, 0x0D, 0x03, 0x66, 0x02, 0xDD])
        )
    }

    func testTumoCardContractRejectsInvalidBounds() {
        XCTAssertNil(TumoCardNFCContract.select(Data()))
        XCTAssertNil(TumoCardNFCContract.select(Data(repeating: 0, count: 17)))
        XCTAssertNil(TumoCardNFCContract.read(length: 0))
        XCTAssertNil(TumoCardNFCContract.read(length: 256))
        XCTAssertNil(TumoCardNFCContract.update(offset: -1, data: Data([0x01])))
        XCTAssertNil(TumoCardNFCContract.update(offset: 0x1_0000, data: Data([0x01])))
        XCTAssertNil(TumoCardNFCContract.update(offset: 0, data: Data()))
    }
}
