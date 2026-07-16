import Foundation

enum TumoSpectrumReportError: Error, Equatable, LocalizedError {
    case malformedAnnouncement
    case unsupportedSchema(Int)
    case invalidReport(String)

    var errorDescription: String? {
        switch self {
        case .malformedAnnouncement:
            return "The TumoSpectrum announcement is malformed."
        case .unsupportedSchema(let schema):
            return "TumoSpectrum report schema \(schema) is not supported."
        case .invalidReport(let reason):
            return "The TumoSpectrum report is invalid: \(reason)."
        }
    }
}

struct TumoSpectrumAnnouncement: Equatable {
    static let appID = "signal_workbench"
    static let command = "report"
    static let reportDirectory = "/ext/apps_data/signal_workbench/reports"

    let schema: Int
    let fileName: String
    let type: String
    let frequencyHz: UInt64
    let similarity: Int
    let sampleCount: Int
    let stablePercent: Int

    var isCaptureSet: Bool { schema == 2 }

    var path: String { "\(Self.reportDirectory)/\(fileName)" }

    static func accepts(_ frame: AppBridgeFrame) -> Bool {
        frame.version == 2 && frame.flags == 0 && frame.requestID == 0 &&
            frame.appID == appID && frame.command == command
    }

    static func parse(_ data: Data) throws -> TumoSpectrumAnnouncement {
        guard data.count <= AppBridgeFrame.payloadMaxV2,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            throw TumoSpectrumReportError.malformedAnnouncement
        }

        var values: [String: String] = [:]
        for component in text.split(separator: ";", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw TumoSpectrumReportError.malformedAnnouncement }
            let key = String(pair[0])
            let value = String(pair[1])
            guard !key.isEmpty, !value.isEmpty, values[key] == nil else {
                throw TumoSpectrumReportError.malformedAnnouncement
            }
            values[key] = value
        }

        guard let schemaText = values["schema"], let schema = Int(schemaText) else {
            throw TumoSpectrumReportError.malformedAnnouncement
        }
        switch schema {
        case 1:
            let expectedKeys: Set<String> = ["schema", "file", "type", "freq", "sim"]
            guard Set(values.keys) == expectedKeys,
                  let fileName = values["file"], isSafeCaptureReportFileName(fileName),
                  let type = values["type"], validTypes.contains(type),
                  let frequencyText = values["freq"], let frequencyHz = UInt64(frequencyText),
                  let similarityText = values["sim"], let similarity = Int(similarityText),
                  frequencyHz <= 1_000_000_000, (0...100).contains(similarity) else {
                throw TumoSpectrumReportError.malformedAnnouncement
            }
            return TumoSpectrumAnnouncement(
                schema: schema,
                fileName: fileName,
                type: type,
                frequencyHz: frequencyHz,
                similarity: similarity,
                sampleCount: 1,
                stablePercent: similarity
            )
        case 2:
            let expectedKeys: Set<String> = ["schema", "file", "kind", "samples", "stable"]
            guard Set(values.keys) == expectedKeys,
                  values["kind"] == "capture_set",
                  let fileName = values["file"], isSafeCaptureSetFileName(fileName),
                  let samplesText = values["samples"], let sampleCount = Int(samplesText),
                  let stableText = values["stable"], let stablePercent = Int(stableText),
                  (3...4).contains(sampleCount), (0...100).contains(stablePercent) else {
                throw TumoSpectrumReportError.malformedAnnouncement
            }
            return TumoSpectrumAnnouncement(
                schema: schema,
                fileName: fileName,
                type: "CAPTURE SET",
                frequencyHz: 0,
                similarity: stablePercent,
                sampleCount: sampleCount,
                stablePercent: stablePercent
            )
        default:
            throw TumoSpectrumReportError.unsupportedSchema(schema)
        }
    }

    static func isSafeReportFileName(_ name: String) -> Bool {
        isSafeCaptureReportFileName(name) || isSafeCaptureSetFileName(name)
    }

    static func sortStamp(_ name: String) -> String {
        if isSafeCaptureReportFileName(name) { return String(name.dropFirst(9).dropLast(5)) }
        if isSafeCaptureSetFileName(name) { return String(name.dropFirst(4).dropLast(5)) }
        return ""
    }

    private static func isSafeCaptureReportFileName(_ name: String) -> Bool {
        isSafeTimestampedFileName(name, prefix: "spectrum_")
    }

    private static func isSafeCaptureSetFileName(_ name: String) -> Bool {
        isSafeTimestampedFileName(name, prefix: "set_")
    }

    private static func isSafeTimestampedFileName(_ name: String, prefix: String) -> Bool {
        guard name.count == prefix.count + 20,
              name.hasPrefix(prefix), name.hasSuffix(".json"),
              !name.contains("/"), !name.contains("\\") else { return false }

        let stamp = name.dropFirst(prefix.count).dropLast(5)
        guard stamp.count == 15 else { return false }
        for (index, character) in stamp.enumerated() {
            if index == 8 {
                guard character == "_" else { return false }
            } else if !isASCIIDigit(character) {
                return false
            }
        }
        return true
    }

    private static let validTypes: Set<String> = ["SUB RAW", "SUB KEY", "IR RAW", "IR KEY", "GPIO", "RF NOTE"]

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (48...57).contains(scalar.value)
    }
}

struct TumoSpectrumReport: Codable, Equatable {
    let schema: Int
    let app: String
    let version: String
    let createdAt: String
    let capture: Capture
    let compared: Capture?
    let comparison: Comparison?

    enum CodingKeys: String, CodingKey {
        case schema, app, version, capture, compared, comparison
        case createdAt = "created_at"
    }

    struct Capture: Codable, Equatable {
        let type: String
        let name: String
        let path: String
        let `protocol`: String
        let preset: String
        let note: String
        let frequencyHz: UInt64
        let fileSize: UInt64
        let truncated: Bool
        let timings: UInt64
        let durationUs: UInt64
        let minUs: UInt64
        let avgUs: UInt64
        let maxUs: UInt64
        let bursts: UInt64
        let repeatScore: Int
        let candidate: String
        let histogram: [Int]

        enum CodingKeys: String, CodingKey {
            case type, name, path, `protocol`, preset, note, truncated, timings, bursts, candidate, histogram
            case frequencyHz = "frequency_hz"
            case fileSize = "file_size"
            case durationUs = "duration_us"
            case minUs = "min_us"
            case avgUs = "avg_us"
            case maxUs = "max_us"
            case repeatScore = "repeat_score"
        }
    }

    struct Comparison: Codable, Equatable {
        let compatible: Bool
        let likelySame: Bool
        let frequencyDeltaHz: Int64
        let pulseDelta: Int64
        let durationDeltaPercent: Int64
        let histogramSimilarity: Int
        let overallSimilarity: Int

        enum CodingKeys: String, CodingKey {
            case compatible
            case likelySame = "likely_same"
            case frequencyDeltaHz = "frequency_delta_hz"
            case pulseDelta = "pulse_delta"
            case durationDeltaPercent = "duration_delta_percent"
            case histogramSimilarity = "histogram_similarity"
            case overallSimilarity = "overall_similarity"
        }
    }

    static func decodeValidated(_ data: Data) throws -> TumoSpectrumReport {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw TumoSpectrumReportError.invalidReport("file size is outside the accepted range")
        }
        let report: TumoSpectrumReport
        do {
            report = try JSONDecoder().decode(TumoSpectrumReport.self, from: data)
        } catch {
            throw TumoSpectrumReportError.invalidReport("JSON does not match schema v1")
        }
        try report.validate()
        return report
    }

    private func validate() throws {
        guard schema == 1 else { throw TumoSpectrumReportError.unsupportedSchema(schema) }
        guard app == "TumoSpectrum", !version.isEmpty, version.count <= 16,
              !createdAt.isEmpty, createdAt.count <= 32 else {
            throw TumoSpectrumReportError.invalidReport("identity fields are invalid")
        }
        try Self.validate(capture)
        if let compared { try Self.validate(compared) }
        if let comparison {
            guard compared != nil, comparison.compatible,
                  (0...100).contains(comparison.histogramSimilarity),
                  (0...100).contains(comparison.overallSimilarity),
                  (-1_000_000...1_000_000).contains(comparison.durationDeltaPercent) else {
                throw TumoSpectrumReportError.invalidReport("comparison values are invalid")
            }
        } else if compared != nil {
            throw TumoSpectrumReportError.invalidReport("compared capture has no comparison")
        }
    }

    private static func validate(_ capture: Capture) throws {
        let optionalStrings = [capture.protocol, capture.preset, capture.candidate]
        guard !capture.type.isEmpty, capture.type.count <= 64,
              !capture.name.isEmpty, capture.name.count <= 64,
              optionalStrings.allSatisfy({ $0.count <= 64 }),
              capture.note.count <= 96,
              capture.path.hasPrefix("/ext/"), capture.path.count <= 192,
              !capture.path.contains("\0"),
              capture.frequencyHz <= 1_000_000_000,
              capture.fileSize <= 16 * 1024 * 1024,
              capture.timings <= 10_000_000,
              capture.durationUs <= 86_400_000_000,
              capture.bursts <= 65_535,
              (0...100).contains(capture.repeatScore),
              capture.histogram.count == 8,
              capture.histogram.allSatisfy({ (0...100).contains($0) }) else {
            throw TumoSpectrumReportError.invalidReport("capture values are outside bounds")
        }
        if capture.timings > 0 {
            guard capture.minUs <= capture.avgUs, capture.avgUs <= capture.maxUs else {
                throw TumoSpectrumReportError.invalidReport("timing statistics are inconsistent")
            }
        }
    }
}

struct TumoSpectrumCaptureSetReport: Codable, Equatable {
    let schema: Int
    let app: String
    let kind: String
    let version: String
    let createdAt: String
    let device: String
    let control: String
    let captureType: String
    let sampleCount: Int
    let inference: Inference
    let samples: [String]

    enum CodingKeys: String, CodingKey {
        case schema, app, kind, version, device, control, inference, samples
        case createdAt = "created_at"
        case captureType = "capture_type"
        case sampleCount = "sample_count"
    }

    struct Inference: Codable, Equatable {
        let compatible: Bool
        let encoding: String
        let replayClass: String
        let stablePercent: Int
        let stablePoints: Int
        let changingPoints: Int
        let alignedPoints: Int
        let frames: Int
        let clustersUs: [UInt64]
        let bitstream: Bitstream?
        let fields: [Field]?
        let counter: Counter?
        let checksum: Checksum?

        enum CodingKeys: String, CodingKey {
            case compatible, encoding, frames, bitstream, fields, counter, checksum
            case replayClass = "replay_class"
            case stablePercent = "stable_percent"
            case stablePoints = "stable_points"
            case changingPoints = "changing_points"
            case alignedPoints = "aligned_points"
            case clustersUs = "clusters_us"
        }

        struct Bitstream: Codable, Equatable {
            let bitCount: Int
            let reference: String
            let pattern: String
            let stableBits: Int
            let changingBits: Int
            let unknownBits: Int

            enum CodingKeys: String, CodingKey {
                case reference, pattern
                case bitCount = "bit_count"
                case stableBits = "stable_bits"
                case changingBits = "changing_bits"
                case unknownBits = "unknown_bits"
            }
        }

        struct Field: Codable, Equatable, Identifiable {
            let kind: String
            let start: Int
            let length: Int

            var id: String { "\(kind)-\(start)-\(length)" }
        }

        struct Counter: Codable, Equatable {
            let found: Bool
            let direction: String
            let start: Int
            let length: Int
            let confidence: Int
        }

        struct Checksum: Codable, Equatable {
            let candidates: [String]
            let start: Int
            let length: Int
            let confidence: Int
        }
    }

    static func decodeValidated(_ data: Data) throws -> TumoSpectrumCaptureSetReport {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw TumoSpectrumReportError.invalidReport("file size is outside the accepted range")
        }
        let report: TumoSpectrumCaptureSetReport
        do {
            report = try JSONDecoder().decode(TumoSpectrumCaptureSetReport.self, from: data)
        } catch {
            throw TumoSpectrumReportError.invalidReport("JSON does not match schema v2")
        }
        try report.validate()
        return report
    }

    private func validate() throws {
        let validCaptureTypes: Set<String> = ["SUB RAW", "IR RAW"]
        let validEncodings: Set<String> = [
            "Unknown encoding", "Pulse pairs", "PWM candidate", "PPM candidate", "Manchester-like"
        ]
        let validReplayClasses: Set<String> = ["Static-like", "Changing / unknown"]
        guard schema == 2 else { throw TumoSpectrumReportError.unsupportedSchema(schema) }
        guard app == "TumoSpectrum", kind == "capture_set",
              !version.isEmpty, version.count <= 16,
              !createdAt.isEmpty, createdAt.count <= 32,
              !device.isEmpty, device.count <= 31,
              !control.isEmpty, control.count <= 31,
              validCaptureTypes.contains(captureType),
              (3...4).contains(sampleCount), samples.count == sampleCount,
              samples.allSatisfy({ !$0.isEmpty && $0.count <= 64 && !$0.contains("\0") }),
              inference.compatible,
              validEncodings.contains(inference.encoding),
              validReplayClasses.contains(inference.replayClass),
              (0...100).contains(inference.stablePercent),
              (1...512).contains(inference.alignedPoints),
              (0...512).contains(inference.stablePoints),
              (0...512).contains(inference.changingPoints),
              inference.stablePoints + inference.changingPoints == inference.alignedPoints,
              (1...65_535).contains(inference.frames),
              (1...4).contains(inference.clustersUs.count),
              inference.clustersUs.allSatisfy({ (1...60_000_000).contains($0) }) else {
            throw TumoSpectrumReportError.invalidReport("capture-set values are outside bounds")
        }
        try validatePhaseB()
    }

    private func validatePhaseB() throws {
        let componentsPresent = [
            inference.bitstream != nil,
            inference.fields != nil,
            inference.counter != nil,
            inference.checksum != nil
        ]
        guard componentsPresent.allSatisfy({ !$0 }) || componentsPresent.allSatisfy({ $0 }) else {
            throw TumoSpectrumReportError.invalidReport("phase-b inference is incomplete")
        }
        guard let bitstream = inference.bitstream,
              let fields = inference.fields,
              let counter = inference.counter,
              let checksum = inference.checksum else { return }

        let referenceCharacters = Set(bitstream.reference)
        let patternCharacters = Set(bitstream.pattern)
        guard (0...96).contains(bitstream.bitCount),
              bitstream.reference.count == bitstream.bitCount,
              bitstream.pattern.count == bitstream.bitCount,
              referenceCharacters.isSubset(of: Set("01?")),
              patternCharacters.isSubset(of: Set("01*?")),
              (0...bitstream.bitCount).contains(bitstream.stableBits),
              (0...bitstream.bitCount).contains(bitstream.changingBits),
              (0...bitstream.bitCount).contains(bitstream.unknownBits),
              bitstream.stableBits + bitstream.changingBits + bitstream.unknownBits == bitstream.bitCount,
              bitstream.pattern.filter({ $0 == "*" }).count == bitstream.changingBits,
              bitstream.pattern.filter({ $0 == "?" }).count == bitstream.unknownBits,
              bitstream.pattern.filter({ $0 == "0" || $0 == "1" }).count == bitstream.stableBits,
              fields.count <= 12 else {
            throw TumoSpectrumReportError.invalidReport("bitstream values are outside bounds")
        }

        let validFieldKinds: Set<String> = ["stable", "changing", "unknown"]
        var previousEnd = 0
        for field in fields {
            guard validFieldKinds.contains(field.kind), field.length > 0,
                  field.start >= previousEnd,
                  field.start + field.length <= bitstream.bitCount else {
                throw TumoSpectrumReportError.invalidReport("candidate fields are invalid")
            }
            previousEnd = field.start + field.length
        }

        if counter.found {
            guard ["incrementing", "decrementing"].contains(counter.direction),
                  (2...16).contains(counter.length), counter.start >= 0,
                  counter.start + counter.length <= bitstream.bitCount,
                  (1...100).contains(counter.confidence) else {
                throw TumoSpectrumReportError.invalidReport("counter candidate is invalid")
            }
        } else {
            guard counter.direction == "none", counter.start == 0,
                  counter.length == 0, counter.confidence == 0 else {
                throw TumoSpectrumReportError.invalidReport("empty counter candidate is invalid")
            }
        }

        let validChecksums: Set<String> = ["xor8", "sum8", "crc8-07", "crc8-31"]
        guard checksum.candidates.count <= validChecksums.count,
              Set(checksum.candidates).count == checksum.candidates.count,
              Set(checksum.candidates).isSubset(of: validChecksums) else {
            throw TumoSpectrumReportError.invalidReport("checksum candidates are invalid")
        }
        if checksum.candidates.isEmpty {
            guard checksum.start == 0, checksum.length == 0, checksum.confidence == 0 else {
                throw TumoSpectrumReportError.invalidReport("empty checksum candidate is invalid")
            }
        } else {
            guard checksum.length == 8, checksum.start >= 0,
                  checksum.start + checksum.length <= bitstream.bitCount,
                  (1...100).contains(checksum.confidence) else {
                throw TumoSpectrumReportError.invalidReport("checksum candidate range is invalid")
            }
        }
    }
}

enum TumoSpectrumDocument: Equatable {
    case capture(TumoSpectrumReport)
    case captureSet(TumoSpectrumCaptureSetReport)

    private struct SchemaEnvelope: Decodable {
        let schema: Int
    }

    static func decodeValidated(_ data: Data) throws -> TumoSpectrumDocument {
        guard !data.isEmpty, data.count <= 64 * 1024 else {
            throw TumoSpectrumReportError.invalidReport("file size is outside the accepted range")
        }
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw TumoSpectrumReportError.invalidReport("schema field is missing")
        }
        switch envelope.schema {
        case 1:
            return .capture(try TumoSpectrumReport.decodeValidated(data))
        case 2:
            return .captureSet(try TumoSpectrumCaptureSetReport.decodeValidated(data))
        default:
            throw TumoSpectrumReportError.unsupportedSchema(envelope.schema)
        }
    }
}
