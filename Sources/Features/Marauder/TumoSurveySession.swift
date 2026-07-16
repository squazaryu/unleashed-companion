import Foundation

struct TumoSurveySessionMetadata: Equatable {
    let schema: Int
    let mode: Int
    let fileName: String
    let accessPoints: Int
    let observations: Int

    var modeLabel: String {
        switch mode {
        case 0: return "Scan All"
        case 1: return "Access Points"
        case 2: return "Wardrive"
        default: return "Mode \(mode)"
        }
    }

    static func parse(_ data: Data) -> TumoSurveySessionMetadata? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for component in text.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }

        guard let schema = fields["schema"].flatMap(Int.init),
              let mode = fields["mode"].flatMap(Int.init),
              schema == 1 else { return nil }

        return TumoSurveySessionMetadata(
            schema: schema,
            mode: mode,
            fileName: fields["file"] ?? "",
            accessPoints: fields["aps"].flatMap(Int.init) ?? 0,
            observations: fields["obs"].flatMap(Int.init) ?? 0
        )
    }
}

enum TumoSurveySessionTransition: Equatable {
    case ignored
    case started
    case data
    case stopped
}

struct TumoSurveySessionState: Equatable {
    private(set) var isActive = false
    private(set) var metadata: TumoSurveySessionMetadata?

    static func accepts(command: String) -> Bool {
        switch command {
        case "live_line", "survey_start", "survey_stop": return true
        default: return false
        }
    }

    mutating func apply(command: String, payload: Data) -> TumoSurveySessionTransition {
        switch command {
        case "survey_start":
            metadata = TumoSurveySessionMetadata.parse(payload)
            isActive = true
            return .started
        case "live_line":
            isActive = true
            return .data
        case "survey_stop":
            metadata = TumoSurveySessionMetadata.parse(payload) ?? metadata
            isActive = false
            return .stopped
        default:
            return .ignored
        }
    }
}

enum TumoSurveySecurity: String, CaseIterable, Hashable, Identifiable {
    case open = "Open"
    case legacy = "Legacy"
    case wpa2 = "WPA2"
    case wpa3 = "WPA3"
    case other = "Other"

    var id: String { rawValue }

    static func classify(_ auth: String) -> TumoSurveySecurity {
        let value = auth.uppercased()
        if value.contains("WPA3") || value.contains("SAE") || value.contains("OWE") {
            return .wpa3
        }
        if value.contains("WPA2") || value.contains("RSN") {
            return .wpa2
        }
        if value.contains("WEP") || value.contains("WPA") {
            return .legacy
        }
        if value.contains("OPEN") || value.contains("NONE") || value.contains("OPN") {
            return .open
        }
        return .other
    }
}

enum TumoSurveyReport {
    static func make(
        result: MarauderParseResult,
        metadata: TumoSurveySessionMetadata?
    ) -> String {
        let securityCounts = Dictionary(grouping: result.aps) {
            TumoSurveySecurity.classify($0.auth)
        }.mapValues { $0.count }
        let sessionName: String
        if let fileName = metadata?.fileName, !fileName.isEmpty {
            sessionName = fileName
        } else {
            sessionName = "live"
        }

        var lines = [
            "TumoSurvey Network Report",
            "Session: \(sessionName)",
            "Mode: \(metadata?.modeLabel ?? "Unknown")",
            "Networks: \(result.aps.count)",
            "Open: \(securityCounts[.open, default: 0])",
            "Legacy: \(securityCounts[.legacy, default: 0])",
            "WPA2: \(securityCounts[.wpa2, default: 0])",
            "WPA3: \(securityCounts[.wpa3, default: 0])",
            "Other: \(securityCounts[.other, default: 0])",
            "",
            "SSID | BSSID | Channel | RSSI | Security",
        ]

        let sorted = result.aps.sorted { ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }
        for accessPoint in sorted {
            let ssid = accessPoint.ssid.isEmpty ? "<hidden>" : accessPoint.ssid
            let channel = accessPoint.channel.map(String.init) ?? "-"
            let rssi = accessPoint.rssi.map { "\($0) dBm" } ?? "-"
            let security = TumoSurveySecurity.classify(accessPoint.auth).rawValue
            lines.append("\(ssid) | \(accessPoint.bssid) | \(channel) | \(rssi) | \(security)")
        }

        return lines.joined(separator: "\n")
    }
}
