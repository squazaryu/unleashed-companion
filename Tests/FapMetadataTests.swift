import XCTest
@testable import UnleashedCompanion

/// Tests for the shared FAP/FAL metadata parser and compatibility policy (issue #19).
/// A deterministic synthetic ELF32-LE builder produces `.fapmeta`-bearing binaries so
/// the parser and policy are exercised without any device or real payload.
final class FapMetadataTests: XCTestCase {

    // MARK: - Synthetic FAP builder

    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func put(_ b: inout [UInt8], _ off: Int, _ v: [UInt8]) {
        for (i, byte) in v.enumerated() { b[off + i] = byte }
    }

    /// Build a minimal but well-formed ELF32-LE FAP: ELF header, a `.fapmeta` section,
    /// and a `.shstrtab`. Parameters let each test perturb exactly one thing.
    private func makeFAP(apiMajor: Int, apiMinor: Int, target: Int,
                         magic: Int = FapMetadata.manifestMagic,
                         version: Int = 1,
                         metaSectionName: String = ".fapmeta",
                         fapmetaOffsetOverride: Int? = nil) -> Data {
        // ELF header (52 bytes).
        var bytes = [UInt8](repeating: 0, count: 52)
        put(&bytes, 0, [0x7F, 0x45, 0x4C, 0x46])   // "\x7FELF"
        bytes[4] = 1   // ELFCLASS32
        bytes[5] = 1   // ELFDATA2LSB
        bytes[6] = 1   // EV_CURRENT
        put(&bytes, 16, le16(1))       // e_type = ET_REL
        put(&bytes, 18, le16(0x28))    // e_machine = ARM
        put(&bytes, 20, le32(1))       // e_version
        put(&bytes, 40, le16(52))      // e_ehsize
        put(&bytes, 46, le16(40))      // e_shentsize
        put(&bytes, 48, le16(3))       // e_shnum
        put(&bytes, 50, le16(2))       // e_shstrndx

        // `.fapmeta` content at offset 52 (14 bytes).
        let fapmetaOffset = 52
        var meta: [UInt8] = []
        meta += le32(magic)
        meta += le32(version)
        meta += le16(apiMinor)
        meta += le16(apiMajor)
        meta += le16(target)
        bytes += meta

        // `.shstrtab` content: "\0<metaName>\0.shstrtab\0".
        let shstrOffset = bytes.count
        let shstr = "\0" + metaSectionName + "\0.shstrtab\0"
        let shstrBytes = Array(shstr.utf8)
        let metaNameIndex = 1
        let strtabNameIndex = 1 + metaSectionName.utf8.count + 1
        bytes += shstrBytes

        // Section header table, 4-aligned.
        var shoff = bytes.count
        shoff = (shoff + 3) & ~3
        put(&bytes, 32, le32(shoff))   // e_shoff (patched into the header)
        while bytes.count < shoff { bytes.append(0) }

        func sectionHeader(name: Int, type: Int, offset: Int, size: Int) -> [UInt8] {
            var h = [UInt8](repeating: 0, count: 40)
            put(&h, 0, le32(name))
            put(&h, 4, le32(type))
            put(&h, 16, le32(offset))
            put(&h, 20, le32(size))
            return h
        }
        bytes += sectionHeader(name: 0, type: 0, offset: 0, size: 0)   // [0] NULL
        bytes += sectionHeader(name: metaNameIndex, type: 1,
                               offset: fapmetaOffsetOverride ?? fapmetaOffset, size: 14)   // [1] .fapmeta
        bytes += sectionHeader(name: strtabNameIndex, type: 3,
                               offset: shstrOffset, size: shstrBytes.count)   // [2] .shstrtab
        return Data(bytes)
    }

    // MARK: - Parser

    func testParsesValidFapmeta() {
        let meta = FapMetadata.parse(makeFAP(apiMajor: 88, apiMinor: 15, target: 7))
        XCTAssertEqual(meta?.apiMajor, 88)
        XCTAssertEqual(meta?.apiMinor, 15)
        XCTAssertEqual(meta?.hardwareTarget, 7)
        XCTAssertEqual(meta?.apiVersionString, "88.15")
    }

    func testBadMagicRejected() {
        XCTAssertNil(FapMetadata.parse(makeFAP(apiMajor: 88, apiMinor: 0, target: 7, magic: 0x0BAD_0BAD)))
    }

    func testUnsupportedManifestVersionRejected() {
        XCTAssertNil(FapMetadata.parse(makeFAP(apiMajor: 88, apiMinor: 0, target: 7, version: 2)))
    }

    func testMissingFapmetaSectionRejected() {
        // No section named ".fapmeta" — the payload has ".other" instead.
        XCTAssertNil(FapMetadata.parse(makeFAP(apiMajor: 88, apiMinor: 0, target: 7, metaSectionName: ".other")))
    }

    func testTruncatedElfRejectedWithoutCrash() {
        let full = makeFAP(apiMajor: 88, apiMinor: 0, target: 7)
        // No prefix length, however short, may trap the parser.
        for cut in 0 ..< full.count { _ = FapMetadata.parse(full.prefix(cut)) }
        // Cutting into the ELF header, `.fapmeta`, string table, or section table
        // removes data the parser needs → it must reject (return nil).
        for cut in [0, 4, 16, 30, 52, 66, 90, 130] {
            XCTAssertNil(FapMetadata.parse(full.prefix(cut)), "truncation at \(cut) should not parse")
        }
    }

    func testOutOfRangeSectionOffsetRejected() {
        // `.fapmeta` sh_offset points far past the end of the file.
        XCTAssertNil(FapMetadata.parse(makeFAP(apiMajor: 88, apiMinor: 0, target: 7,
                                               fapmetaOffsetOverride: 0x4000_0000)))
    }

    func testNonElfRejected() {
        XCTAssertNil(FapMetadata.parse(Data([0x01, 0x02, 0x03])))
        XCTAssertNil(FapMetadata.parse(Data()))
        XCTAssertNil(FapMetadata.parse(Data("not an elf at all, just text".utf8)))
    }

    func testWrongElfClassOrEndiannessRejected() {
        var d = Array(makeFAP(apiMajor: 88, apiMinor: 0, target: 7))
        d[4] = 2   // ELFCLASS64
        XCTAssertNil(FapMetadata.parse(Data(d)))
        d[4] = 1; d[5] = 2   // big-endian
        XCTAssertNil(FapMetadata.parse(Data(d)))
    }

    // MARK: - Policy (mirrors the firmware loader: major== & target==)

    private let dev88t7 = (api: 88, target: 7)

    func testAPI88AcceptedOn88() {
        let v = FapCompatibility.classify(
            data: makeFAP(apiMajor: 88, apiMinor: 0, target: 7),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case let .compatible(m) = v else { return XCTFail("expected compatible, got \(v)") }
        XCTAssertEqual(m.apiMajor, 88)
    }

    func testAPI87RejectedOn88() {
        let v = FapCompatibility.classify(
            data: makeFAP(apiMajor: 87, apiMinor: 15, target: 7),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case let .incompatible(reason) = v else { return XCTFail("expected incompatible") }
        XCTAssertTrue(reason.contains("API 87.15"), reason)
        XCTAssertTrue(reason.contains("firmware API 87"), reason)
        XCTAssertTrue(reason.contains("firmware API 88"), reason)
    }

    func testAPI89RejectedOn88() {
        let v = FapCompatibility.classify(
            data: makeFAP(apiMajor: 89, apiMinor: 0, target: 7),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case .incompatible = v else { return XCTFail("expected incompatible") }
    }

    func testMinorMismatchAccepted() {
        // Same major, wildly different minor → still compatible (loader minor check disabled).
        let v = FapCompatibility.classify(
            data: makeFAP(apiMajor: 88, apiMinor: 999, target: 7),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case .compatible = v else { return XCTFail("minor should not block, got \(v)") }
    }

    func testTargetMismatchRejected() {
        let v = FapCompatibility.classify(
            data: makeFAP(apiMajor: 88, apiMinor: 0, target: 18),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case let .incompatible(reason) = v else { return XCTFail("expected incompatible") }
        XCTAssertTrue(reason.contains("target 18"), reason)
        XCTAssertTrue(reason.contains("device target 7"), reason)
    }

    func testInvalidMetadataBlocks() {
        let v = FapCompatibility.classify(
            data: Data([0, 1, 2, 3]),
            deviceApiMajor: dev88t7.api, deviceTarget: dev88t7.target)
        guard case let .incompatible(reason) = v else { return XCTFail("expected incompatible") }
        XCTAssertTrue(reason.contains("Invalid FAP metadata"), reason)
    }

    func testUnknownDeviceBlocksFailClosed() {
        let data = makeFAP(apiMajor: 88, apiMinor: 0, target: 7)
        guard case let .unvalidated(r1) = FapCompatibility.classify(
            data: data, deviceApiMajor: nil, deviceTarget: 7)
        else { return XCTFail("nil api should block") }
        XCTAssertEqual(r1, "Connect Flipper to validate app compatibility")
        guard case .unvalidated = FapCompatibility.classify(
            data: data, deviceApiMajor: 88, deviceTarget: nil)
        else { return XCTFail("nil target should block") }
    }

    func testIsBinaryDetection() {
        XCTAssertTrue(FapCompatibility.isBinary("/ext/apps/Games/x.fap"))
        XCTAssertTrue(FapCompatibility.isBinary("/ext/apps/Games/x.FAP"))
        XCTAssertTrue(FapCompatibility.isBinary("/ext/apps_data/arf/modules/y.fal"))
        XCTAssertFalse(FapCompatibility.isBinary("/ext/apps_data/foo/data.bin"))
        XCTAssertFalse(FapCompatibility.isBinary("/ext/apps/Games/x.fap.png"))
    }

    // MARK: - Shared gate over a mixed archive (both installer flows call THIS)

    func testMixedArchiveSurfacesOnlyRejected() {
        let good = makeFAP(apiMajor: 88, apiMinor: 0, target: 7)
        let oldApi = makeFAP(apiMajor: 87, apiMinor: 15, target: 7)
        let wrongTarget = makeFAP(apiMajor: 88, apiMinor: 0, target: 18)
        let dataFile = Data("just an asset, not a fap".utf8)

        let blocked = PackageCompatibilityGate.blocked(
            [
                (id: "good", target: "/ext/apps/Tools/good.fap", data: { good }),
                (id: "old", target: "/ext/apps/Games/old.fap", data: { oldApi }),
                (id: "target", target: "/ext/apps/NFC/t.fap", data: { wrongTarget }),
                (id: "asset", target: "/ext/apps_data/x/data.bin", data: { dataFile }),
                (id: "missing", target: "/ext/apps/USB/gone.fap", data: { nil }),
            ],
            deviceApiMajor: 88, deviceTarget: 7)

        XCTAssertNil(blocked["good"])                       // compatible → not blocked
        XCTAssertNil(blocked["asset"])                      // not a binary → never checked
        XCTAssertNotNil(blocked["old"])                     // API major mismatch
        XCTAssertNotNil(blocked["target"])                  // target mismatch
        XCTAssertNotNil(blocked["missing"])                 // bytes unavailable → fail closed
        XCTAssertEqual(Set(blocked.keys), ["old", "target", "missing"])
    }
}
