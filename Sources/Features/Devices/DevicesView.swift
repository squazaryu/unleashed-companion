import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject private var buddy = BuddyRelay.shared
    @ObservedObject private var layout = HomeLayoutStore.shared
    @Binding var path: [HomeTileID]
    @State private var showCustomize = false

    private let cols = [GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            CardScroll {
                connectionCard
                if ble.state != .ready && !ble.discovered.isEmpty { nearbyCard }
                if buddy.enabled { buddyCard }
                ForEach(HomeGroupID.allCases) { groupCard($0) }
                versionFooter
            }
            .navigationTitle("Home")
            .navigationDestination(for: HomeTileID.self) { destination($0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCustomize = true } label: { Image(systemName: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if ble.state == .connected || ble.state == .ready {
                        Button("Disconnect") { ble.disconnect() }
                    } else {
                        Button {
                            ble.state == .scanning ? ble.stopScan() : ble.startScan()
                        } label: {
                            Image(systemName: ble.state == .scanning ? "stop.circle" : "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCustomize) {
                NavigationStack { CustomizeHomeView() }
            }
            .onAppear { if ble.state == .disconnected { ble.autoConnect() } }
        }
    }

    // MARK: - Connection hero

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 52, height: 52)
                    Image(systemName: ble.state == .ready ? "checkmark" :
                            (ble.state == .scanning ? "dot.radiowaves.left.and.right" : "bolt.horizontal"))
                        .font(.title3).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.connectedName ?? "Flipper Zero").font(.title3).fontWeight(.semibold)
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if ble.state == .ready, let b = ble.battery {
                    batteryBadge(b)
                }
            }
            HStack(spacing: 8) {
                StatusPill(text: ble.state == .ready ? "Ready" : statusShort,
                           color: color)
                if ble.state == .ready {
                    StatusPill(text: ble.supportsAppBridge ? (ble.appBridgeV2 ? "Bridge v2" : "Bridge v1") : "No bridge",
                               color: ble.supportsAppBridge ? (ble.appBridgeV2 ? .green : .secondary) : .orange,
                               systemImage: "antenna.radiowaves.left.and.right")
                }
                StatusPill(
                    text: "Files \(transfer.activeChannel.label)",
                    color: transfer.activeChannel == .usb ? .blue : .secondary,
                    systemImage: transfer.activeChannel.systemImage
                )
                Spacer()
                if ble.state != .ready && ble.state != .connected {
                    Button {
                        ble.state == .scanning ? ble.stopScan() : ble.startScan()
                    } label: {
                        Label(ble.state == .scanning ? "Scanning…" : "Scan",
                              systemImage: ble.state == .scanning ? "stop.circle" : "arrow.clockwise")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: color)
    }

    private var nearbyCard: some View {
        SectionCard(title: "Nearby", systemImage: "wave.3.right") {
            VStack(spacing: 10) {
                ForEach(ble.discovered) { f in
                    Button { ble.connect(f.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.subheadline).fontWeight(.medium)
                                Text(f.id.uuidString.prefix(8)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            signal(f.rssi)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var buddyCard: some View {
        SectionCard(title: "Claude Buddy", systemImage: "bell.badge.fill",
                    accessory: AnyView(
                        StatusPill(text: buddy.active ? "Active" : "Idle",
                                   color: buddy.active ? .green : .secondary)
                    )) {
            if let last = buddy.lastEvent {
                Text(last).font(.subheadline)
            } else {
                Text(buddy.active ? "Buddy app is talking to the Flipper."
                                  : "Idle — opens automatically when the Buddy app is in front on the Flipper.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Collapsible tile groups

    @ViewBuilder private func groupCard(_ group: HomeGroupID) -> some View {
        let tiles = layout.tiles(group)
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation(.snappy) { layout.toggle(group) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.systemImage).font(.caption).foregroundStyle(Theme.accent)
                        Text(group.name.uppercased())
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary).tracking(0.5)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(layout.isExpanded(group) ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if layout.isExpanded(group) {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(tiles) { tile in
                            NavigationLink(value: tile) { DashTile(spec: tile.spec) }
                                .buttonStyle(.plain)
                                .disabled(isDisabled(tile))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder private func destination(_ tile: HomeTileID) -> some View {
        switch tile {
        case .info:    DeviceInfoView()
        case .apps:    InstalledAppsView()
        case .files:   FilesView()
        case .airadar: AIRadarView()
        case .wifi:    TumoSurveyView()
        case .spectrum: TumoSpectrumView()
        case .relay:   BridgeView()
        case .tumonet: TumoNetView()
        case .esp32:   ESP32FirmwareView()
        case .updates: UpdatesView()
        case .backup:  BackupView()
        case .remotes: RemotesView()
        case .media:   MediaRemoteView()
        }
    }

    /// Info needs a live RPC link; the rest open offline (or show their own empty state).
    private func isDisabled(_ tile: HomeTileID) -> Bool { tile == .info && ble.state != .ready }

    private var versionFooter: some View {
        HStack {
            Spacer()
            Text(BuildInfo.label).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private var color: Color {
        switch ble.state {
        case .ready: return .green
        case .connected, .connecting, .scanning: return .yellow
        case .poweredOff, .unauthorized: return .red
        default: return .gray
        }
    }

    private var label: String {
        switch ble.state {
        case .ready: return "Connected & ready"
        case .connected: return "Connecting services…"
        case .connecting: return "Connecting…"
        case .scanning: return "Scanning for Flippers"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not authorized"
        default: return "Not connected"
        }
    }

    private var statusShort: String {
        switch ble.state {
        case .scanning: return "Scanning"
        case .connecting, .connected: return "Connecting"
        case .poweredOff: return "BT off"
        default: return "Offline"
        }
    }

    private func batteryBadge(_ level: Int) -> some View {
        let color: Color = level <= 15 ? .red : level <= 30 ? .orange : .green
        let icon = level <= 10 ? "battery.0" : level <= 35 ? "battery.25"
                 : level <= 60 ? "battery.50" : level <= 85 ? "battery.75" : "battery.100"
        return VStack(spacing: 2) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text("\(level)%").font(.caption).fontWeight(.semibold).foregroundStyle(color)
        }
    }

    private func signal(_ rssi: Int) -> some View {
        let bars = rssi > -55 ? 3 : rssi > -70 ? 2 : 1
        return HStack(spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Theme.accent : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
        }
    }
}

struct DashTileSpec {
    let title: String
    let systemImage: String
    let tint: Color
}

struct DashTile: View {
    let spec: DashTileSpec
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: spec.systemImage)
                .font(.title3).foregroundStyle(spec.tint)
            Text(spec.title).font(.caption).fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(spec.tint.opacity(0.12), lineWidth: 1))
    }
}
