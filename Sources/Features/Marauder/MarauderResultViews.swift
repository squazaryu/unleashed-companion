import SwiftUI

/// Shared AP/client list rendering for any `MarauderParseResult` — used by both the
/// offline pcap/log analysis flow (`MarauderView`) and the live BLE scan flow
/// (`MarauderLiveView`), so both present networks/clients identically instead of two
/// screens inventing their own row styles.

@ViewBuilder func marauderNetworksCard(_ r: MarauderParseResult) -> some View {
    CollapsibleCard(title: "Networks", systemImage: "wifi",
                    accessory: AnyView(StatusPill(text: "\(r.aps.count)", color: .secondary))) {
        VStack(spacing: 4) {
            ForEach(r.aps) { ap in
                let clients = r.clients(of: ap.bssid)
                // Only offer a disclosure arrow when there is actually something to
                // expand — a TumoSurvey scan yields AP beacons only (no client
                // associations), so most rows have no clients and an always-present
                // chevron that opens to nothing is just misleading. Clients do appear
                // from the offline pcap/sniff flow, where the arrow stays useful.
                if clients.isEmpty {
                    marauderAPRow(ap, clients: clients)
                } else {
                    DisclosureGroup {
                        VStack(spacing: 8) { ForEach(clients) { marauderClientRow($0) } }.padding(.top, 4)
                    } label: {
                        marauderAPRow(ap, clients: clients)
                    }
                    .tint(.secondary)
                }
                Divider().opacity(0.3)
            }
        }
    }
}

/// One access-point row: SSID, BSSID·vendor, and — on the trailing edge — channel,
/// signal (RSSI, parsed but previously never surfaced), and a client-count pill.
private func marauderAPRow(_ ap: MarauderAP, clients: [MarauderStation]) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(ap.ssid.isEmpty ? "<hidden>" : ap.ssid).font(.subheadline).fontWeight(.medium)
                if let lock = marauderLock(ap.auth) {
                    Image(systemName: lock.symbol).font(.caption2).foregroundStyle(lock.color)
                }
            }
            Text(ap.bssid + (ap.vendor.map { $0 == "Unknown" ? "" : " · \($0)" } ?? ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if let c = ap.channel { Text("ch \(c)").font(.caption2).foregroundStyle(.secondary) }
                if let rssi = ap.rssi {
                    Label("\(rssi) dBm", systemImage: rssi < -85 ? "wifi.slash" : "wifi")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(rssi >= -67 ? Color.green : rssi >= -80 ? Color.secondary : Color.orange)
                }
            }
            if !clients.isEmpty {
                StatusPill(text: "\(clients.count)", color: Theme.accent, systemImage: "person.fill")
            }
        }
    }
}

/// Encryption indicator from a Marauder `auth` token (wardrive only): open networks
/// get an orange unlocked glyph, secured ones a muted padlock, unknown/blank nothing.
private func marauderLock(_ auth: String) -> (symbol: String, color: Color)? {
    let a = auth.uppercased()
    if a.isEmpty { return nil }
    if a.contains("OPEN") { return ("lock.open.fill", .orange) }
    return ("lock.fill", .secondary)
}

@ViewBuilder func marauderOtherClientsCard(_ r: MarauderParseResult) -> some View {
    CollapsibleCard(title: "Unassociated clients", systemImage: "person.2",
                    accessory: AnyView(StatusPill(text: "\(r.unassociatedStations.count)", color: .secondary))) {
        VStack(spacing: 8) { ForEach(r.unassociatedStations) { marauderClientRow($0) } }
    }
}

func marauderClientRow(_ s: MarauderStation) -> some View {
    HStack {
        Image(systemName: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 1) {
            Text(s.mac).font(.system(.caption, design: .monospaced))
            if let v = s.vendor, v != "Unknown" { Text(v).font(.caption2).foregroundStyle(.secondary) }
        }
        Spacer()
        Text("\(s.packets) pkt").font(.caption2).foregroundStyle(.secondary)
    }
}
