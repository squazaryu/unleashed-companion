import Foundation

/// Parsed `.fapmeta` of a Flipper application binary (FAP/FAL). Mirrors the firmware
/// struct `FlipperApplicationManifestBase`
/// (`lib/flipper_application/application_manifest.h`):
///
///     magic:u32(0)  manifest_version:u32(4)
///     api_version { minor:u16(8)  major:u16(10) }  hardware_target_id:u16(12)
///
/// Every read is bounds-checked against the backing `Data`; any malformed, truncated,
/// oversized, or non-ELF32-LE input yields `nil` rather than trapping.
struct FapMetadata: Equatable {
    let apiMajor: Int
    let apiMinor: Int
    let hardwareTarget: Int

    static let manifestMagic = 0x5247_4448          // 'HDGR' little-endian
    static let supportedManifestVersion = 1
    static let sectionName = ".fapmeta"

    /// Full binary API as displayed for diagnostics, e.g. "87.15".
    var apiVersionString: String { "\(apiMajor).\(apiMinor)" }

    /// Parse a FAP/FAL binary (ELF32 little-endian) and extract `.fapmeta`. Returns nil
    /// for anything that isn't a well-formed ELF32-LE carrying a valid, supported
    /// `.fapmeta` (bad magic, unsupported manifest version, missing section, or any
    /// offset/length that would read out of bounds).
    static func parse(_ data: Data) -> FapMetadata? {
        let r = ByteReader(data)

        // ELF identification: "\x7FELF", 32-bit class, little-endian data.
        guard r.u8(0) == 0x7F, r.u8(1) == 0x45, r.u8(2) == 0x4C, r.u8(3) == 0x46,
              r.u8(4) == 1 /* ELFCLASS32 */, r.u8(5) == 1 /* ELFDATA2LSB */ else { return nil }

        // ELF32 header fields we need (little-endian offsets per the spec).
        guard let shoff = r.u32(32),          // e_shoff — section header table offset
              let shentsize = r.u16(46),      // e_shentsize
              let shnum = r.u16(48),          // e_shnum
              let shstrndx = r.u16(50),       // e_shstrndx — section-name string table index
              shentsize >= 40, shnum > 0, shstrndx < shnum else { return nil }

        // The section-name string table (.shstrtab) header.
        let strHdr = shoff + shstrndx * shentsize
        guard let strOffset = r.u32(strHdr + 16),   // sh_offset
              let strSize = r.u32(strHdr + 20)       // sh_size
        else { return nil }

        // Walk the sections; resolve each name from the string table; find `.fapmeta`.
        for i in 0 ..< shnum {
            let hdr = shoff + i * shentsize
            guard let nameIndex = r.u32(hdr + 0) else { return nil }   // sh_name
            guard let name = r.cString(base: strOffset, limit: strSize, offset: nameIndex),
                  name == sectionName else { continue }

            guard let secOffset = r.u32(hdr + 16),   // sh_offset
                  let secSize = r.u32(hdr + 20),      // sh_size
                  secSize >= 14 else { return nil }

            guard let magic = r.u32(secOffset), magic == manifestMagic,
                  let version = r.u32(secOffset + 4), version == supportedManifestVersion,
                  let minor = r.u16(secOffset + 8),
                  let major = r.u16(secOffset + 10),
                  let target = r.u16(secOffset + 12) else { return nil }

            return FapMetadata(apiMajor: major, apiMinor: minor, hardwareTarget: target)
        }
        return nil   // no `.fapmeta` section present
    }
}

/// Explicit per-entry compatibility state for a catalog FAP/FAL. The single source of
/// truth the UI, the selection policy, and the install gate all derive from — so policy
/// is never duplicated. Only `.compatible` is installable.
///
///   • `unvalidated` — the connected firmware API/target isn't known yet (no BLE-ready
///     device_info). Not installable; carries a "connect a Flipper" reason.
///   • `compatible(metadata)` — passes the loader policy for the connected firmware.
///   • `incompatible(reason)` — parsed but rejected (API-major/target mismatch), or the
///     binary metadata is invalid/missing. Not installable.
enum FapCompatibilityState: Equatable {
    case unvalidated(String)
    case compatible(FapMetadata)
    case incompatible(reason: String)

    var isCompatible: Bool { if case .compatible = self { return true }; return false }
    /// Installable == compatible. Unvalidated and incompatible entries are never installed.
    var isInstallable: Bool { isCompatible }

    var metadata: FapMetadata? { if case let .compatible(m) = self { return m }; return nil }

    /// User-facing reason to show on a blocked row (nil when compatible).
    var reason: String? {
        switch self {
        case .unvalidated(let r): return r
        case .incompatible(let r): return r
        case .compatible: return nil
        }
    }
}

/// Shared FAP/FAL compatibility policy — used identically by BOTH install flows
/// (`TumoflipUpdater` / FW Packages and `PluginUpdater` / All the Plugins).
///
/// Mirrors the firmware ELF loader (`flipper_application_manifest_*`):
///   • hardware target must equal the connected device target;
///   • API **major** must equal the connected firmware API major
///     (`major <` → ApiTooOld, `major >` → ApiTooNew are both rejected);
///   • the minor is preserved and shown for diagnostics but does not itself block while
///     the firmware loader's minor check stays disabled.
enum FapCompatibility {
    static let unknownDeviceReason = "Connect Flipper to validate app compatibility"

    /// True for payloads that carry `.fapmeta` and must be API-checked. Plain data
    /// files (icons, assets, protocol-pack data, …) are validated by size/SHA elsewhere.
    static func isBinary(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".fap") || p.hasSuffix(".fal")
    }

    /// Classify already-parsed metadata (nil = a binary whose `.fapmeta` was invalid /
    /// unparseable) against the connected firmware. Fail-closed on an unknown device.
    static func classify(_ metadata: FapMetadata?, deviceApiMajor: Int?, deviceTarget: Int?) -> FapCompatibilityState {
        guard let deviceApiMajor, let deviceTarget else { return .unvalidated(unknownDeviceReason) }
        guard let m = metadata else { return .incompatible(reason: "Invalid FAP metadata") }
        if m.hardwareTarget != deviceTarget {
            return .incompatible(reason: "API \(m.apiVersionString) · target \(m.hardwareTarget); connected device target \(deviceTarget)")
        }
        if m.apiMajor != deviceApiMajor {
            return .incompatible(reason: "API \(m.apiVersionString) · requires firmware API \(m.apiMajor); connected firmware API \(deviceApiMajor)")
        }
        return .compatible(m)
    }

    /// Classify raw bytes (parsing once). `nil` bytes = the file isn't present in the
    /// package → incompatible (never silently skipped).
    static func classify(data: Data?, deviceApiMajor: Int?, deviceTarget: Int?) -> FapCompatibilityState {
        guard deviceApiMajor != nil, deviceTarget != nil else { return .unvalidated(unknownDeviceReason) }
        guard let data else { return .incompatible(reason: "File not found in package") }
        return classify(FapMetadata.parse(data), deviceApiMajor: deviceApiMajor, deviceTarget: deviceTarget)
    }
}

/// The single choke point both installer flows (`TumoflipUpdater` / FW Packages and
/// `PluginUpdater` / All the Plugins) run their selected payloads through before any
/// staging/backup/cleanup/write. Given each candidate's id, install target, and a lazy
/// byte accessor, it returns `id → reason` for every FAP/FAL that must NOT be installed.
/// Non-binary data files are never included (they keep their existing size/SHA checks);
/// a binary whose bytes can't be read is failed closed.
enum PackageCompatibilityGate {
    struct Candidate {
        let id: String
        let target: String
        let data: () -> Data?
    }

    static func blocked(_ candidates: [Candidate],
                        deviceApiMajor: Int?, deviceTarget: Int?) -> [String: String] {
        var out: [String: String] = [:]
        for c in candidates where FapCompatibility.isBinary(c.target) {
            let state = FapCompatibility.classify(data: c.data(), deviceApiMajor: deviceApiMajor, deviceTarget: deviceTarget)
            if !state.isInstallable { out[c.id] = state.reason ?? "Incompatible with the connected firmware" }
        }
        return out
    }

    /// Convenience for call sites that already hold tuples.
    static func blocked(_ candidates: [(id: String, target: String, data: () -> Data?)],
                        deviceApiMajor: Int?, deviceTarget: Int?) -> [String: String] {
        blocked(candidates.map { Candidate(id: $0.id, target: $0.target, data: $0.data) },
                deviceApiMajor: deviceApiMajor, deviceTarget: deviceTarget)
    }

    /// One-line install-failure summary naming the blocked files (id → reason).
    static func summary(_ hits: [String: String]) -> String {
        let names = hits.keys.map { ($0 as NSString).lastPathComponent }.sorted()
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? " +\(names.count - 4) more" : ""
        return "Incompatible with the connected firmware: \(shown)\(more). Nothing was written."
    }
}

/// Little-endian, fully bounds-checked reader over a `Data`. All offsets are `Int`
/// (64-bit), so a hostile 32-bit ELF offset near `UInt32.max` simply fails the range
/// check and returns nil — it can never index out of bounds.
private struct ByteReader {
    private let data: Data
    private let start: Data.Index
    private let count: Int

    init(_ data: Data) {
        self.data = data
        self.start = data.startIndex
        self.count = data.count
    }

    func u8(_ off: Int) -> Int? {
        guard off >= 0, off < count else { return nil }
        return Int(data[start + off])
    }

    func u16(_ off: Int) -> Int? {
        guard off >= 0, off + 2 <= count else { return nil }
        let b = start + off
        return Int(data[b]) | (Int(data[b + 1]) << 8)
    }

    func u32(_ off: Int) -> Int? {
        guard off >= 0, off + 4 <= count else { return nil }
        let b = start + off
        return Int(data[b]) | (Int(data[b + 1]) << 8) | (Int(data[b + 2]) << 16) | (Int(data[b + 3]) << 24)
    }

    /// A NUL-terminated string beginning at `base + offset`, constrained to the
    /// `[base, base + limit)` string-table window and the data bounds.
    func cString(base: Int, limit: Int, offset: Int) -> String? {
        guard base >= 0, limit >= 0, offset >= 0, offset < limit,
              base <= count, base + limit <= count else { return nil }
        var bytes: [UInt8] = []
        var p = base + offset
        let end = base + limit
        while p < end {
            let c = data[start + p]
            if c == 0 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(c)
            p += 1
        }
        return nil   // unterminated within the string table
    }
}
