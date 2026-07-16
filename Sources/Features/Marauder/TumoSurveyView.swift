import Charts
import SwiftUI

struct TumoSurveyView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @StateObject private var live = LiveMarauderViewModel()

    var body: some View {
        CardScroll {
            statusCard
            if !live.result.aps.isEmpty {
                overviewCard
                marauderNetworksCard(live.result)
            }
            toolsCard
        }
        .navigationTitle("TumoSurvey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { live.clear() } label: {
                    Image(systemName: "trash")
                }
                .disabled(live.linesReceived == 0)
                .accessibilityLabel("Clear live survey")
            }
        }
        .task { live.start() }
        .onDisappear { live.stop() }
    }

    private var statusCard: some View {
        SectionCard(
            title: "Survey",
            systemImage: "dot.radiowaves.left.and.right",
            accessory: AnyView(
                StatusPill(
                    text: statusLabel,
                    color: statusColor,
                    systemImage: live.session.isActive ? "wave.3.right" : nil
                )
            )
        ) {
            if !ble.appBridgeV2 {
                Label("App Bridge v2 is unavailable for this firmware.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                HStack {
                    statTile("\(live.result.aps.count)", "networks")
                    statTile("\(live.linesReceived)", "rows")
                    statTile("\(securedCount)", "secured")
                }

                if let metadata = live.session.metadata {
                    Divider().opacity(0.35)
                    HStack {
                        Label(metadata.modeLabel, systemImage: "scope")
                        Spacer()
                        Text(metadata.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !live.session.isActive {
                    Text("Waiting for an active survey.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var overviewCard: some View {
        SectionCard(title: "Live Insights", systemImage: "chart.bar.xaxis") {
            HStack {
                statTile("\(securityCount(.open))", "open")
                statTile("\(securityCount(.legacy))", "legacy")
                statTile("\(securityCount(.wpa2))", "WPA2")
                statTile("\(securityCount(.wpa3))", "WPA3")
            }

            if !channelCounts.isEmpty {
                Divider().opacity(0.35)
                Chart(channelCounts) { item in
                    BarMark(
                        x: .value("Channel", String(item.channel)),
                        y: .value("Networks", item.count)
                    )
                    .foregroundStyle(Theme.accent)
                }
                .frame(height: 112)
                .accessibilityLabel("Networks by WiFi channel")
            }
        }
    }

    private var toolsCard: some View {
        SectionCard(title: "Workspace", systemImage: "square.grid.2x2") {
            NavigationLink { WiFiMapperLiveMapView() } label: {
                toolRow(
                    icon: "location.viewfinder",
                    title: "Live Map",
                    detail: "iPhone GPS observations"
                )
            }
            .buttonStyle(.plain)

            Divider().opacity(0.35)

            NavigationLink { WiFiMapperMapView() } label: {
                toolRow(
                    icon: "map.fill",
                    title: "Saved Maps",
                    detail: "GeoJSON survey exports"
                )
            }
            .buttonStyle(.plain)

            Divider().opacity(0.35)

            NavigationLink { MarauderView() } label: {
                toolRow(
                    icon: "waveform.path.ecg.rectangle",
                    title: "Capture Analysis",
                    detail: "PCAP and ESP32 logs"
                )
            }
            .buttonStyle(.plain)

            Divider().opacity(0.35)

            ShareLink(
                item: reportText,
                subject: Text("TumoSurvey Network Report")
            ) {
                toolRow(
                    icon: "square.and.arrow.up",
                    title: "Export Report",
                    detail: "Human-readable network inventory"
                )
            }
            .buttonStyle(.plain)
            .disabled(live.result.aps.isEmpty)
        }
    }

    private var statusLabel: String {
        guard ble.appBridgeV2 else { return "No bridge" }
        if live.session.isActive { return "Live" }
        if live.session.metadata != nil { return "Saved" }
        return "Ready"
    }

    private var statusColor: Color {
        guard ble.appBridgeV2 else { return .orange }
        return live.session.isActive ? .green : .secondary
    }

    private var securedCount: Int {
        securityCount(.legacy) + securityCount(.wpa2) + securityCount(.wpa3)
    }

    private func securityCount(_ security: TumoSurveySecurity) -> Int {
        live.result.aps.reduce(into: 0) { count, accessPoint in
            if TumoSurveySecurity.classify(accessPoint.auth) == security {
                count += 1
            }
        }
    }

    private var channelCounts: [ChannelCount] {
        Dictionary(grouping: live.result.aps.compactMap(\.channel), by: { $0 })
            .map { ChannelCount(channel: $0.key, count: $0.value.count) }
            .sorted { $0.channel < $1.channel }
    }

    private var reportText: String {
        TumoSurveyReport.make(result: live.result, metadata: live.session.metadata)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func toolRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct ChannelCount: Identifiable {
    let channel: Int
    let count: Int
    var id: Int { channel }
}
