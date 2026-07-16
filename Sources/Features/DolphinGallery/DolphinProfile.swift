import Foundation

enum DolphinProfileOrder: String, Codable, CaseIterable, Identifiable {
    case random = "Random"
    case sequential = "Sequential"

    var id: String { rawValue }
    var label: String { rawValue }
}

enum DolphinProfileTiming: String, Codable, CaseIterable, Identifiable {
    case original = "Original"
    case custom = "Custom"

    var id: String { rawValue }
    var label: String { rawValue }
}

struct DolphinDesktopProfile: Equatable {
    static let minimumDuration = 5
    static let maximumDuration = 86_399
    static let maximumAnimationCount = 128
    static let maximumCollectionBytes = 64

    var enabled: Bool
    var collection: String
    var order: DolphinProfileOrder
    var timing: DolphinProfileTiming
    var durationSeconds: Int
    var animationIDs: [String]

    func encoded() throws -> Data {
        guard !enabled || (!collection.isEmpty && !animationIDs.isEmpty) else {
            throw DolphinProfileError.emptyCollection
        }
        guard Self.isValidCollectionName(collection) else {
            throw DolphinProfileError.invalidCollection
        }
        guard (Self.minimumDuration...Self.maximumDuration).contains(durationSeconds) else {
            throw DolphinProfileError.invalidDuration
        }
        guard animationIDs.count <= Self.maximumAnimationCount,
              Set(animationIDs).count == animationIDs.count,
              animationIDs.allSatisfy(Self.isValidAnimationID) else {
            throw DolphinProfileError.invalidAnimation
        }

        var lines = [
            "Filetype: Tumoflip Desktop Profile",
            "Version: 1",
            "Enabled: \(enabled ? "true" : "false")",
            "Collection: \(collection)",
            "Order: \(order.rawValue)",
            "Timing: \(timing.rawValue)",
            "Duration: \(durationSeconds)",
        ]
        lines.append(contentsOf: animationIDs.map { "Animation: \($0)" })
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    static func decode(_ data: Data) throws -> DolphinDesktopProfile {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DolphinProfileError.invalidEncoding
        }

        var values: [String: String] = [:]
        var animations: [String] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator])
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if key == "Animation" {
                animations.append(value)
            } else {
                values[key] = value
            }
        }

        guard values["Filetype"] == "Tumoflip Desktop Profile",
              values["Version"] == "1",
              let enabledText = values["Enabled"],
              let enabled = Bool(enabledText),
              let collection = values["Collection"],
              let orderText = values["Order"],
              let order = DolphinProfileOrder(rawValue: orderText),
              let timingText = values["Timing"],
              let timing = DolphinProfileTiming(rawValue: timingText),
              let durationText = values["Duration"],
              let duration = Int(durationText) else {
            throw DolphinProfileError.invalidFormat
        }

        let profile = DolphinDesktopProfile(
            enabled: enabled,
            collection: collection,
            order: order,
            timing: timing,
            durationSeconds: duration,
            animationIDs: animations
        )
        _ = try profile.encoded()
        return profile
    }

    private static func isValidAnimationID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 96 else { return false }
        return value.utf8.allSatisfy {
            ($0 >= Character("0").asciiValue! && $0 <= Character("9").asciiValue!) ||
                ($0 >= Character("A").asciiValue! && $0 <= Character("Z").asciiValue!) ||
                ($0 >= Character("a").asciiValue! && $0 <= Character("z").asciiValue!) ||
                $0 == Character("_").asciiValue! || $0 == Character("-").asciiValue!
        }
    }

    private static func isValidCollectionName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumCollectionBytes else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }
}

enum DolphinProfileError: LocalizedError, Equatable {
    case emptyCollection
    case invalidCollection
    case invalidAnimation
    case invalidDuration
    case invalidEncoding
    case invalidFormat
    case stagedProfileMismatch

    var errorDescription: String? {
        switch self {
        case .emptyCollection:
            return "Select at least one animation before enabling the profile."
        case .invalidCollection:
            return "Collection names must fit in 64 bytes and cannot contain line breaks."
        case .invalidAnimation:
            return "The collection contains an unsupported animation name."
        case .invalidDuration:
            return "Duration must be between 5 and 86399 seconds."
        case .invalidEncoding:
            return "The profile is not valid UTF-8."
        case .invalidFormat:
            return "The Flipper returned an invalid desktop profile."
        case .stagedProfileMismatch:
            return "The profile could not be verified on the Flipper."
        }
    }
}

struct DolphinAnimation: Identifiable, Hashable, Codable {
    let id: String
    let source: DolphinLibrarySource
    let previewURL: URL?

    init(
        id: String,
        source: DolphinLibrarySource = .legacy,
        previewURL: URL? = nil
    ) {
        self.id = id
        self.source = source
        self.previewURL = previewURL
    }

    var title: String {
        var value = id
        if value.first == "L", value.count > 3, value[value.index(value.startIndex, offsetBy: 2)] == "_" {
            value.removeFirst(3)
        }
        if let sizeRange = value.range(of: #"_128x\d+$"#, options: .regularExpression) {
            value.removeSubrange(sizeRange)
        }
        return value.replacingOccurrences(of: "_", with: " ")
    }

    var previewAsset: String? {
        source == .legacy ? "Dolphin_\(id)" : nil
    }
}

enum DolphinCatalog {
    static let legacy: [DolphinAnimation] = [
        "L1_Tv_128x47",
        "L1_Waves_128x50",
        "L1_Laptop_128x51",
        "L1_Sleep_128x64",
        "L1_Recording_128x51",
        "L1_Furippa1_128x64",
        "L1_Read_books_128x64",
        "L1_Cry_128x64",
        "L1_Boxing_128x64",
        "L1_Mad_fist_128x64",
        "L1_Mods_128x64",
        "L1_Painting_128x64",
        "L1_Leaving_sad_128x64",
        "L1_Senpai_128x64",
        "L1_Kaiju_128x64",
        "L1_My_dude_128x64",
        "L2_Wake_up_128x64",
        "L2_Furippa2_128x64",
        "L2_Hacking_pc_128x64",
        "L2_Soldering_128x64",
        "L2_Dj_128x64",
        "L3_Furippa3_128x64",
        "L3_Hijack_radio_128x64",
        "L3_Lab_research_128x54",
        "L1_Sad_song_128x64",
        "L2_Coding_in_the_shell_128x64",
        "L2_Secret_door_128x64",
        "L3_Freedom_2_dolphins_128x64",
        "L1_Akira_128x64",
        "L3_Intruder_alert_128x64",
        "L1_Procrastinating_128x64",
        "L1_Showtime_128x64",
        "L3_Fireplace_128x64",
        "L2_FlipperCity_128x64",
        "L3_FlipperMustache_128x64",
        "L1_Doom_128x64",
    ].map { DolphinAnimation(id: $0) }

    static let animations = legacy
}

struct DolphinCollection: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var animationIDs: [String]
}
