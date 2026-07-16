import Foundation

struct MarauderAP: Identifiable, Equatable, Codable {
    var id = UUID()
    var ssid: String
    var bssid: String
    var rssi: Int?
    var channel: Int?
    var clients: Int = 0
    var vendor: String?
    var auth: String = ""   // encryption token, e.g. "[WPA2_PSK]" / "[OPEN]" (wardrive lines)
}

/// A client/station seen on the air, optionally associated with an AP (BSSID).
struct MarauderStation: Identifiable, Equatable, Codable {
    var id = UUID()
    var mac: String
    var bssid: String?       // associated AP, if known
    var vendor: String?      // from MAC OUI ("Randomized" for private MACs)
    var packets: Int = 0
}

struct CapturedCredential: Identifiable, Equatable, Codable {
    var id = UUID()
    var username: String
    var password: String
    var source: String
}

struct MarauderParseResult: Equatable, Codable {
    var aps: [MarauderAP] = []
    var stations: [MarauderStation] = []
    var credentials: [CapturedCredential] = []
    var handshakes: Int = 0
    var rawLines: Int = 0

    /// Stations grouped under their AP (BSSID), plus the unassociated ones.
    func clients(of bssid: String) -> [MarauderStation] {
        stations.filter { $0.bssid?.caseInsensitiveCompare(bssid) == .orderedSame }
    }
    var unassociatedStations: [MarauderStation] { stations.filter { $0.bssid == nil } }

    /// Merge several parsed captures into one: networks deduped by BSSID, clients by
    /// MAC (packets summed), credentials deduped, client counts recomputed.
    static func aggregate(_ results: [MarauderParseResult]) -> MarauderParseResult {
        var apByBSSID: [String: MarauderAP] = [:]
        var staByMAC: [String: MarauderStation] = [:]
        var creds: [CapturedCredential] = []
        var handshakes = 0, rawLines = 0
        for r in results {
            for ap in r.aps {
                var m = apByBSSID[ap.bssid] ?? MarauderAP(ssid: ap.ssid, bssid: ap.bssid)
                if m.ssid.isEmpty { m.ssid = ap.ssid }
                if m.channel == nil { m.channel = ap.channel }
                if m.rssi == nil { m.rssi = ap.rssi }
                if m.vendor == nil || m.vendor == "Unknown" { m.vendor = ap.vendor }
                if m.auth.isEmpty { m.auth = ap.auth }
                apByBSSID[ap.bssid] = m
            }
            for st in r.stations {
                var m = staByMAC[st.mac] ?? MarauderStation(mac: st.mac, vendor: st.vendor)
                if m.bssid == nil { m.bssid = st.bssid }
                if m.vendor == nil || m.vendor == "Unknown" { m.vendor = st.vendor }
                m.packets += st.packets
                staByMAC[st.mac] = m
            }
            creds += r.credentials
            handshakes += r.handshakes
            rawLines += r.rawLines
        }
        for key in apByBSSID.keys { apByBSSID[key]!.clients = 0 }
        for st in staByMAC.values where st.bssid != nil {
            if var ap = apByBSSID[st.bssid!] { ap.clients += 1; apByBSSID[st.bssid!] = ap }
        }
        var seen = Set<String>()
        var out = MarauderParseResult()
        out.aps = apByBSSID.values.sorted { ($0.clients, $0.ssid) > ($1.clients, $1.ssid) }
        out.stations = staByMAC.values.sorted { $0.packets > $1.packets }
        out.credentials = creds.filter { seen.insert("\($0.username)|\($0.password)").inserted && (!$0.username.isEmpty || !$0.password.isEmpty) }
        out.handshakes = handshakes
        out.rawLines = rawLines
        return out
    }
}

/// Classifies a Marauder file so the picker can filter out noise (info/help/etc.).
enum MarauderLogKind: String, CaseIterable {
    case capture, scan, portal, other
    var label: String {
        switch self {
        case .capture: return "Captures"
        case .scan:    return "Scans"
        case .portal:  return "Portal"
        case .other:   return "Other"
        }
    }
    static func of(_ name: String) -> MarauderLogKind {
        let n = name.lowercased()
        let ext = (n as NSString).pathExtension
        if ext == "pcap" || ext == "pcapng" { return .capture }
        if n.contains("portal") { return .portal }
        let base = (n as NSString).lastPathComponent
        for p in ["scan", "wardrive", "list", "sniff"] where base.hasPrefix(p) { return .scan }
        return .other
    }
}

/// Offline parser for Marauder scan logs and Evil Portal capture files stored
/// on the Flipper SD. Mirrors the heuristics used by the Python
/// `marauder_analyzer` but kept dependency-free for iOS.
enum MarauderLogParser {
    private static let mac = try! NSRegularExpression(
        pattern: "([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5})")

    static func parse(_ text: String) -> MarauderParseResult {
        var result = MarauderParseResult()
        var byBSSID: [String: MarauderAP] = [:]
        let lines = text.split(whereSeparator: \.isNewline)
        result.rawLines = lines.count

        for raw in lines {
            let line = String(raw)
            let lower = line.lowercased()

            // Evil Portal / form captures: email=..&password=.. (user's format)
            if let cred = credential(in: line) {
                result.credentials.append(cred)
            }

            if lower.contains("eapol") || lower.contains("handshake") {
                result.handshakes += 1
            }

            // Wardrive rows have a different, comma-delimited shape than the
            // scanall/scanap lines (no "ESSID:"/"Ch:"), so parse them explicitly —
            // otherwise the generic path below grabs a MAC fragment as the SSID.
            if let wd = wardriveFields(in: line) {
                var ap = byBSSID[wd.bssid] ?? MarauderAP(ssid: wd.ssid, bssid: wd.bssid)
                if ap.ssid.isEmpty { ap.ssid = wd.ssid }
                if let r = wd.rssi { ap.rssi = r }
                if let c = wd.channel { ap.channel = c }
                if ap.auth.isEmpty { ap.auth = wd.auth }
                byBSSID[wd.bssid] = ap
                continue
            }

            // Access points: any line with a MAC, capture SSID + signal/channel.
            if let bssid = firstMAC(in: line) {
                var ap = byBSSID[bssid] ?? MarauderAP(ssid: ssid(in: line, bssid: bssid),
                                                      bssid: bssid)
                if ap.ssid.isEmpty { ap.ssid = ssid(in: line, bssid: bssid) }
                if let r = signedInt(after: ["rssi", "dbm"], in: lower) ?? looseRSSI(in: line) {
                    ap.rssi = r
                }
                if let c = intValue(after: ["ch", "channel"], in: lower) { ap.channel = c }
                byBSSID[bssid] = ap
            }
        }
        result.aps = byBSSID.values.sorted { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
        return result
    }

    private static func credential(in line: String) -> CapturedCredential? {
        func value(_ key: String) -> String? {
            // matches key=VALUE up to & or whitespace
            guard let range = line.range(of: "\(key)=", options: .caseInsensitive) else { return nil }
            let rest = line[range.upperBound...]
            let end = rest.firstIndex { $0 == "&" || $0 == " " || $0 == "\"" } ?? rest.endIndex
            let v = String(rest[rest.startIndex..<end])
            return v.removingPercentEncoding ?? v
        }
        let user = value("email") ?? value("username") ?? value("user") ?? value("login")
        let pass = value("password") ?? value("pass") ?? value("pwd")
        if let user, let pass, !user.isEmpty || !pass.isEmpty {
            return CapturedCredential(username: user, password: pass, source: "Evil Portal")
        }
        return nil
    }

    private static func firstMAC(in line: String) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = mac.firstMatch(in: line, range: range),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r]).uppercased()
    }

    /// Parses a Marauder wardrive row:
    /// `<idx> | <bssid>,<ssid>,<auth>,,<ch>,<rssi>,<lat>,<lon>,<alt>,<acc>,WIFI`
    /// (optionally prefixed with "[BUF/CLOSE]"). Returns nil for non-wardrive lines.
    private static func wardriveFields(in line: String)
        -> (bssid: String, ssid: String, auth: String, channel: Int?, rssi: Int?)? {
        guard let bar = line.range(of: "|") else { return nil }
        let comps = line[bar.upperBound...]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard comps.count >= 7, comps.last?.uppercased() == "WIFI",
              let bssid = firstMAC(in: comps[0]) else { return nil }
        // A hidden network reports its own BSSID as the SSID — blank it so it
        // renders as <hidden> rather than a MAC, matching the scanall parser.
        let ssid = firstMAC(in: comps[1]) == nil ? comps[1] : ""
        return (bssid, ssid, comps[2], Int(comps[4]), Int(comps[5]))
    }

    private static func ssid(in line: String, bssid: String) -> String {
        // Marauder scanall/scanap: "<rssi> Ch: <n> <BSSID> ESSID: <name> <hh> <hh>".
        // Take the text after ESSID:/SSID: and drop the trailing 2-hex flag tokens
        // Marauder appends (e.g. " 11 04").
        if let r = line.range(of: "ESSID:", options: .caseInsensitive)
                ?? line.range(of: "SSID:", options: .caseInsensitive) {
            var tokens = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                .split(separator: " ").map(String.init)
            while let last = tokens.last, last.count == 2, last.allSatisfy(\.isHexDigit) {
                tokens.removeLast()
            }
            let name = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && firstMAC(in: name) == nil { return name }
        }
        // Legacy "idx: SSID, rssi, ch, BSSID" format.
        if let comma = line.firstIndex(of: ":") {
            let after = line[line.index(after: comma)...]
            let parts = after.split(separator: ",")
            if let first = parts.first {
                let candidate = first.trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && firstMAC(in: candidate) == nil { return candidate }
            }
        }
        return ""
    }

    private static func looseRSSI(in line: String) -> Int? {
        for token in line.split(whereSeparator: { ",: ".contains($0) }) {
            if let v = Int(token), v < 0, v > -120 { return v }
        }
        return nil
    }

    private static func signedInt(after keys: [String], in lower: String) -> Int? {
        for key in keys {
            if let r = lower.range(of: key) {
                let rest = lower[r.upperBound...].drop { !"-0123456789".contains($0) }
                let num = rest.prefix { "-0123456789".contains($0) }
                if let v = Int(num) { return v }
            }
        }
        return nil
    }

    private static func intValue(after keys: [String], in lower: String) -> Int? {
        for key in keys {
            if let r = lower.range(of: "\(key) ") ?? lower.range(of: "\(key):") {
                let rest = lower[r.upperBound...].drop { !"0123456789".contains($0) }
                let num = rest.prefix { "0123456789".contains($0) }
                if let v = Int(num), v <= 196 { return v }
            }
        }
        return nil
    }
}
