import Foundation

/// Minimal 802.11 pcap parser for Marauder sniff captures: extracts access points
/// (beacons/probe-responses), stations (clients), and their AP association, plus a
/// vendor name from the MAC OUI. Dependency-free; handles raw 802.11 (DLT 105) and
/// radiotap-wrapped (DLT 127), little- or big-endian pcap headers.
enum MarauderPcap {

    static func looksLikePcap(_ data: Data) -> Bool {
        if case .classicPcap = detectFormat(data) { return true }
        return false
    }

    /// What kind of file this is, so the UI can explain a "nothing parsed" result
    /// instead of silently showing an empty screen.
    enum Format: Equatable {
        case classicPcap(dlt: Int)   // libpcap; dlt 105 = 802.11, 127 = radiotap
        case pcapng                  // 0x0a0d0d0a — not parsed yet
        case text                    // anything else → text-log heuristics
    }

    static func detectFormat(_ data: Data) -> Format {
        let head = [UInt8](data.prefix(24))
        guard head.count >= 4 else { return .text }
        if Array(head.prefix(4)) == [0x0a, 0x0d, 0x0d, 0x0a] { return .pcapng }
        let classic = Array(head.prefix(4)) == [0xa1, 0xb2, 0xc3, 0xd4]
                   || Array(head.prefix(4)) == [0xd4, 0xc3, 0xb2, 0xa1]
        guard classic, head.count >= 24 else { return .text }
        let le = (head[0] == 0xd4)
        let dlt = le ? Int(head[20]) | Int(head[21]) << 8 | Int(head[22]) << 16 | Int(head[23]) << 24
                     : Int(head[20]) << 24 | Int(head[21]) << 16 | Int(head[22]) << 8 | Int(head[23])
        return .classicPcap(dlt: dlt)
    }

    static func parse(_ data: Data) -> MarauderParseResult? {
        let b = [UInt8](data)
        guard b.count >= 24 else { return nil }
        let le = (b[0] == 0xd4)          // 0xd4c3b2a1 in file order → little-endian
        func u16(_ i: Int) -> Int { le ? Int(b[i]) | Int(b[i+1])<<8 : Int(b[i])<<8 | Int(b[i+1]) }
        func u32(_ i: Int) -> Int {
            le ? Int(b[i]) | Int(b[i+1])<<8 | Int(b[i+2])<<16 | Int(b[i+3])<<24
               : Int(b[i])<<24 | Int(b[i+1])<<16 | Int(b[i+2])<<8 | Int(b[i+3])
        }
        let dlt = u32(20)
        guard dlt == 105 || dlt == 127 else { return nil }   // 802.11 or radiotap

        var apByBSSID: [String: MarauderAP] = [:]
        var staByMAC: [String: MarauderStation] = [:]

        func bumpAP(_ bssid: String, ssid: String?, channel: Int?) {
            guard isRealMAC(bssid) else { return }
            var ap = apByBSSID[bssid] ?? MarauderAP(ssid: ssid ?? "", bssid: bssid)
            if let s = ssid, !s.isEmpty { ap.ssid = s }
            if let c = channel { ap.channel = c }
            ap.vendor = vendor(for: bssid)
            apByBSSID[bssid] = ap
        }
        func bumpStation(_ mac: String, bssid: String?) {
            guard isRealMAC(mac) else { return }
            var st = staByMAC[mac] ?? MarauderStation(mac: mac, vendor: vendor(for: mac))
            if let bs = bssid, isRealMAC(bs) { st.bssid = bs }
            st.packets += 1
            staByMAC[mac] = st
        }

        var off = 24
        while off + 16 <= b.count {
            let inclLen = u32(off + 8)
            off += 16
            guard inclLen > 0, off + inclLen <= b.count else { break }
            var f = off                                   // start of captured frame
            let end = off + inclLen
            off = end                                     // advance to next record

            if dlt == 127 {                               // strip radiotap (it_len is always LE)
                guard f + 4 <= end else { continue }
                let itLen = Int(b[f+2]) | Int(b[f+3])<<8
                f += itLen
            }
            guard f + 24 <= end else { continue }         // need at least the MAC header
            parse80211(b, f, end, bumpAP: bumpAP, bumpStation: bumpStation)
        }

        guard !apByBSSID.isEmpty || !staByMAC.isEmpty else { return nil }
        for st in staByMAC.values where st.bssid != nil {
            if var ap = apByBSSID[st.bssid!] { ap.clients += 1; apByBSSID[st.bssid!] = ap }
        }
        var r = MarauderParseResult()
        r.aps = apByBSSID.values.sorted { ($0.clients, $0.ssid) > ($1.clients, $1.ssid) }
        r.stations = staByMAC.values.sorted { $0.packets > $1.packets }
        return r
    }

    private static func parse80211(_ b: [UInt8], _ f: Int, _ end: Int,
                                   bumpAP: (String, String?, Int?) -> Void,
                                   bumpStation: (String, String?) -> Void) {
        let fc0 = b[f], fc1 = b[f+1]
        let type = (fc0 >> 2) & 0x3
        let subtype = (fc0 >> 4) & 0xF
        let toDS = (fc1 & 0x1) != 0
        let fromDS = (fc1 & 0x2) != 0
        func addr(_ n: Int) -> String { mac(b, f + 4 + n*6) }   // addr1@4, addr2@10, addr3@16

        switch type {
        case 0: // management
            let bssid = addr(2)
            if subtype == 8 || subtype == 5 {           // beacon / probe-response → AP
                var ssid: String? = nil; var channel: Int? = nil
                var t = f + 36                            // 24 hdr + 12 fixed params
                while t + 2 <= end {
                    let tag = Int(b[t]); let len = Int(b[t+1]); let val = t + 2
                    guard val + len <= end else { break }
                    if tag == 0 { ssid = String(bytes: b[val..<val+len], encoding: .utf8) }
                    else if tag == 3, len >= 1 { channel = Int(b[val]) }
                    t = val + len
                }
                bumpAP(bssid, ssid, channel)
            } else if subtype == 4 {                     // probe-request → a roaming client
                bumpStation(addr(1), nil)                 // addr2 (transmitter) is the station
            }
        case 2: // data → station ↔ AP association
            if toDS && !fromDS {           // station → AP : a1=BSSID, a2=station
                bumpAP(addr(0), nil, nil)
                bumpStation(addr(1), addr(0))
            } else if !toDS && fromDS {     // AP → station : a1=station, a2=BSSID
                bumpAP(addr(1), nil, nil)
                bumpStation(addr(0), addr(1))
            } else if !toDS && !fromDS {    // IBSS/ad-hoc : a3=BSSID
                bumpStation(addr(1), addr(2))
            }
        default:
            break
        }
    }

    private static func mac(_ b: [UInt8], _ i: Int) -> String {
        guard i + 6 <= b.count else { return "00:00:00:00:00:00" }
        return (0..<6).map { String(format: "%02X", b[i+$0]) }.joined(separator: ":")
    }

    private static func isRealMAC(_ m: String) -> Bool {
        if m == "FF:FF:FF:FF:FF:FF" || m == "00:00:00:00:00:00" { return false }
        if m.hasPrefix("01:00:5E") || m.hasPrefix("33:33") || m.hasPrefix("01:80:C2") { return false }
        return true
    }

    // MARK: - OUI vendor

    static func vendor(for mac: String) -> String {
        let parts = mac.split(separator: ":")
        guard parts.count >= 1, let first = UInt8(parts[0], radix: 16) else { return "Unknown" }
        if (first & 0x02) != 0 { return "Randomized" }      // locally-administered (private) MAC
        let oui = parts.prefix(3).joined(separator: ":").uppercased()
        return ouiMap[oui] ?? "Unknown"
    }

    /// Compact OUI → vendor map for common consumer devices. (Full IEEE OUI DB is
    /// huge; this covers the manufacturers most likely to show up on a home network.)
    private static let ouiMap: [String: String] = [
        "FC:FB:FB": "Apple", "F0:18:98": "Apple", "A4:83:E7": "Apple", "DC:A9:04": "Apple",
        "AC:DE:48": "Apple", "3C:06:30": "Apple", "F0:99:BF": "Apple", "88:66:5A": "Apple",
        "D0:81:7A": "Apple", "C8:1E:E7": "Apple", "90:72:40": "Apple",
        "DC:A6:32": "Raspberry Pi", "B8:27:EB": "Raspberry Pi", "E4:5F:01": "Raspberry Pi",
        "24:0A:C4": "Espressif", "7C:9E:BD": "Espressif", "A0:20:A6": "Espressif",
        "30:AE:A4": "Espressif", "8C:AA:B5": "Espressif", "C4:4F:33": "Espressif",
        "84:F3:EB": "Espressif", "DC:4F:22": "Espressif", "EC:FA:BC": "Espressif",
        "F4:CF:A2": "Espressif", "B4:E6:2D": "Espressif",
        "00:1A:11": "Google", "F4:F5:E8": "Google", "F8:8F:CA": "Google", "DA:A1:19": "Google",
        "94:EB:2C": "Samsung", "78:BD:BC": "Samsung", "AC:5F:3E": "Samsung", "5C:0A:5B": "Samsung",
        "E8:50:8B": "Samsung", "FC:A1:3E": "Samsung", "8C:77:12": "Samsung",
        "50:EC:50": "Xiaomi", "64:09:80": "Xiaomi", "F8:A4:5F": "Xiaomi", "28:6C:07": "Xiaomi",
        "00:E0:4C": "Realtek", "52:54:00": "QEMU/VM",
        "00:1B:63": "Apple", "B8:E8:56": "Apple", "F0:79:59": "Asus", "AC:9E:17": "Asus",
        "EC:08:6B": "TP-Link", "50:C7:BF": "TP-Link", "C4:6E:1F": "TP-Link", "98:DA:C4": "TP-Link",
        "00:17:88": "Philips Hue", "EC:B5:FA": "Philips Hue",
        "44:65:0D": "Amazon", "FC:65:DE": "Amazon", "68:37:E9": "Amazon", "0C:47:C9": "Amazon",
        "18:B4:30": "Nest", "64:16:66": "Nest",
        "00:1D:0F": "TP-Link", "C0:25:E9": "TP-Link",
        "D8:0D:17": "TP-Link", "60:32:B1": "TP-Link",
        "B0:BE:76": "TP-Link", "AC:84:C6": "TP-Link",
        "00:0C:29": "VMware", "00:50:56": "VMware",
        "DC:68:EB": "Huawei", "48:46:FB": "Huawei", "00:E0:FC": "Huawei",
    ]
}
