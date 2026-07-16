import Foundation

enum TumoflipFirmwareChannel: String, CaseIterable, Identifiable, Equatable {
    case stable
    case dev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stable: return "Stable"
        case .dev: return "Dev"
        }
    }

    var packageLabel: String {
        switch self {
        case .stable: return "main/stable packages"
        case .dev: return "dev packages"
        }
    }

    static func infer(version: String) -> TumoflipFirmwareChannel? {
        if version.hasPrefix("t-dev-") { return .dev }
        let stablePatterns = [
            #"^t-flppr-fw-[0-9]{3}-[0-9]{3}$"#,
            #"^tmwhflpprarf[0-9]{3}-[0-9]{3}$"#,
        ]
        if stablePatterns.contains(where: {
            version.range(of: $0, options: .regularExpression) != nil
        }) {
            return .stable
        }
        return nil
    }
}

struct TumoflipDeviceIdentity: Equatable {
    let firmwareVersion: String?
    let originFork: String?
    let firmwareCommit: String?
    let firmwareCommitDirty: Bool?
    let firmwareAPI: String?
    let hardwareTarget: Int?

    init(
        firmwareVersion: String?,
        originFork: String?,
        firmwareCommit: String?,
        firmwareCommitDirty: Bool?,
        firmwareAPI: String?,
        hardwareTarget: Int?
    ) {
        self.firmwareVersion = firmwareVersion
        self.originFork = originFork
        self.firmwareCommit = firmwareCommit
        self.firmwareCommitDirty = firmwareCommitDirty
        self.firmwareAPI = firmwareAPI
        self.hardwareTarget = hardwareTarget
    }

    init(deviceInfo: [(String, String)]) {
        let dict = Dictionary(deviceInfo, uniquingKeysWith: { first, _ in first })
        let apiParts = [dict["firmware_api_major"], dict["firmware_api_minor"]].compactMap { $0 }
        self.init(
            firmwareVersion: dict["firmware_version"],
            originFork: dict["firmware_origin_fork"],
            firmwareCommit: dict["firmware_commit"],
            firmwareCommitDirty: Self.parseBool(dict["firmware_commit_dirty"]),
            firmwareAPI: apiParts.count == 2 ? apiParts.joined(separator: ".") : nil,
            hardwareTarget: dict["hardware_target"].flatMap(Int.init)
        )
    }

    var isTumoflip: Bool {
        originFork?.caseInsensitiveCompare("tumoflip") == .orderedSame
    }

    var inferredChannel: TumoflipFirmwareChannel? {
        guard isTumoflip, let firmwareVersion else { return nil }
        return TumoflipFirmwareChannel.infer(version: firmwareVersion)
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

struct TumoflipFirmwareRoute: Equatable {
    enum Warning: Equatable {
        case identityUnavailable
        case nonTumoflip(origin: String?)
        case unknownTumoflipVersion(String?)
        case manualOverride(selected: TumoflipFirmwareChannel, detected: TumoflipFirmwareChannel?)

        var message: String {
            switch self {
            case .identityUnavailable:
                return "Installed firmware identity is unavailable. Stable packages are selected until you explicitly choose another channel."
            case .nonTumoflip(let origin):
                return "Connected firmware is not reported as Tumoflip\(origin.map { " (\($0))" } ?? ""). Stable packages are selected; dev packages are never selected automatically."
            case .unknownTumoflipVersion(let version):
                return "Tumoflip version \(version ?? "unknown") does not match a known stable/dev pattern. Stable packages are selected until you explicitly choose another channel."
            case .manualOverride(let selected, let detected):
                if let detected {
                    return "Manual override is using \(selected.packageLabel) instead of detected \(detected.packageLabel). Confirm compatibility before installing."
                }
                return "Manual override is using \(selected.packageLabel) without a detected Tumoflip channel. Confirm compatibility before installing."
            }
        }
    }

    let channel: TumoflipFirmwareChannel
    let detectedChannel: TumoflipFirmwareChannel?
    let warning: Warning?
    let isManualOverride: Bool
}

enum TumoflipFirmwareRouter {
    static func route(
        identity: TumoflipDeviceIdentity?,
        manualOverride: TumoflipFirmwareChannel?
    ) -> TumoflipFirmwareRoute {
        let detected = identity?.inferredChannel
        if let manualOverride {
            return TumoflipFirmwareRoute(
                channel: manualOverride,
                detectedChannel: detected,
                warning: .manualOverride(selected: manualOverride, detected: detected),
                isManualOverride: true
            )
        }

        guard let identity else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .identityUnavailable,
                isManualOverride: false
            )
        }
        guard identity.isTumoflip else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .nonTumoflip(origin: identity.originFork),
                isManualOverride: false
            )
        }
        guard let detected else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .unknownTumoflipVersion(identity.firmwareVersion),
                isManualOverride: false
            )
        }
        return TumoflipFirmwareRoute(
            channel: detected,
            detectedChannel: detected,
            warning: nil,
            isManualOverride: false
        )
    }
}

enum TumoflipPackageReleaseMatcher {
    static func matches(
        manifestVersion: String,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?
    ) -> Bool {
        guard TumoflipFirmwareChannel.infer(version: manifestVersion) == channel else {
            return false
        }
        guard let installedVersion, !installedVersion.isEmpty else {
            return true
        }
        return manifestVersion == installedVersion
    }
}
