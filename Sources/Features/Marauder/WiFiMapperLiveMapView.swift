import SwiftUI
import MapKit
import Combine
import CoreLocation
import UIKit

/// Live WiFi mapping using the **iPhone's GPS** (not an ESP32 GPS module): each
/// scan line relayed from TumoSurvey over App Bridge is tagged with
/// the phone's current position, and the shared `WiFiMapperAPEstimator` triangulates
/// each access point from the RSSI-weighted spread of those observations. Walk/drive
/// while the AP estimates update in real time.
@MainActor
final class WiFiMapperLiveMapViewModel: ObservableObject {
    @Published private(set) var points: [WiFiMapperPoint] = []
    @Published private(set) var estimates: [WiFiMapperAPEstimate] = []
    @Published private(set) var uniqueNetworks = 0
    @Published private(set) var observations = 0
    @Published private(set) var lastObservationAt: Date?
    @Published private(set) var running = false
    @Published private(set) var session = TumoSurveySessionState()

    let location = LocationProvider()
    private let ble: FlipperBLE
    private var relaySub: AnyCancellable?
    private var seq = 0

    init(ble: FlipperBLE = .shared) { self.ble = ble }

    func start() {
        location.start()
        running = true
        guard relaySub == nil else { return }
        relaySub = ble.appBridgeIn
            .filter {
                $0.appID == "wifi_mapper" &&
                TumoSurveySessionState.accepts(command: $0.command)
            }
            .sink { [weak self] frame in self?.handle(frame) }
    }

    func stop() {
        running = false
        relaySub?.cancel(); relaySub = nil
        location.stop()
    }

    func clear() {
        points = []
        estimates = []
        uniqueNetworks = 0
        observations = 0
        lastObservationAt = nil
    }

    private func handle(_ frame: AppBridgeFrame) {
        let transition = session.apply(command: frame.command, payload: frame.payload)
        if transition == .started {
            clear()
            return
        }
        guard transition == .data else { return }
        guard let text = String(data: frame.payload, encoding: .utf8), !text.isEmpty else { return }
        // Every observation is anchored to the phone's position at the moment it
        // arrived — drop the batch if we don't have a usable fix yet.
        guard let fix = location.location, fix.horizontalAccuracy > 0 else { return }
        let coord = fix.coordinate
        let parsed = MarauderLogParser.parse(text)
        var added = false
        for ap in parsed.aps {
            guard let rssi = ap.rssi, !ap.bssid.isEmpty else { continue }
            seq += 1
            points.append(WiFiMapperPoint(
                id: "live|\(ap.bssid)|\(seq)",
                sourceName: "live",
                ssid: ap.ssid,
                bssid: ap.bssid,
                auth: ap.auth,
                channel: ap.channel,
                rssi: rssi,
                bestRSSI: nil, lastRSSI: nil, averageRSSI: nil,
                samples: 1,
                tickMS: nil, firstTickMS: nil, lastTickMS: nil,
                latitude: coord.latitude,
                longitude: coord.longitude,
                altitude: fix.altitude,
                accuracy: fix.horizontalAccuracy))
            observations += 1
            added = true
        }
        // Recompute the (cached) triangulation once per relayed batch that added
        // data — not on every SwiftUI render, and not per estimate access.
        if added {
            lastObservationAt = Date()
            uniqueNetworks = Set(points.map(\.bssid)).count
            estimates = WiFiMapperAPEstimator.estimates(from: points)
        }
    }
}

struct WiFiMapperLiveMapView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = WiFiMapperLiveMapViewModel()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        CardScroll {
            statusCard
            if !vm.points.isEmpty {
                mapCard
                if !vm.estimates.isEmpty { estimatesCard }
            }
        }
        .navigationTitle("Live Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { vm.clear() } label: { Image(systemName: "trash") }
                    .disabled(vm.observations == 0)
            }
        }
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var statusCard: some View {
        SectionCard(title: "Live WiFi Map", systemImage: "location.viewfinder",
                    accessory: AnyView(StatusPill(
                        text: ble.appBridgeV2 ? "App Bridge v2" : "No bridge",
                        color: ble.appBridgeV2 ? .green : .orange,
                        systemImage: "antenna.radiowaves.left.and.right"))) {
            if vm.location.isDenied {
                Label("Location access is off. Enable it in Settings so scans can be placed on the map.",
                      systemImage: "location.slash.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url).font(.caption)
                }
            } else if !ble.appBridgeV2 {
                Label("App Bridge v2 not available — needs a firmware that negotiates it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                gpsRow
                HStack {
                    statTile("\(vm.observations)", "readings")
                    statTile("\(vm.uniqueNetworks)", "networks")
                    statTile("\(vm.estimates.count)", "AP est.")
                }
                if vm.location.location == nil {
                    Label("Waiting for a GPS fix — go outside with a clear sky view.",
                          systemImage: "location.magnifyingglass")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if vm.observations == 0 {
                    Label(vm.session.isActive ? "Survey active — waiting for mapped observations." : "Waiting for an active survey.",
                          systemImage: "figure.walk")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var gpsRow: some View {
        HStack(spacing: 6) {
            Circle().fill(vm.location.location != nil ? .green : .orange).frame(width: 7, height: 7)
            if let fix = vm.location.location {
                Text("GPS ±\(Int(fix.horizontalAccuracy)) m").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Acquiring GPS…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = vm.lastObservationAt {
                Text("last reading \(at, style: .relative) ago")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var mapCard: some View {
        SectionCard(title: "Map", systemImage: "map") {
            Map(position: $position) {
                UserAnnotation()
                ForEach(vm.estimates) { estimate in
                    MapCircle(center: estimate.coordinate, radius: estimate.radiusMeters)
                        .foregroundStyle(confidenceColor(estimate).opacity(0.10))
                        .stroke(confidenceColor(estimate).opacity(0.35), lineWidth: 1)
                }
                ForEach(vm.estimates) { estimate in
                    Annotation(estimate.displaySSID, coordinate: estimate.coordinate) {
                        Image(systemName: "location.circle.fill")
                            .font(.title2)
                            .foregroundStyle(confidenceColor(estimate))
                            .background(.regularMaterial, in: Circle())
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            HStack {
                Button { position = .userLocation(fallback: .automatic) } label: {
                    Label("Follow me", systemImage: "location.fill")
                }
                Spacer()
                Button { position = .automatic } label: {
                    Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var estimatesCard: some View {
        CollapsibleCard(title: "Estimated APs", systemImage: "location.circle",
                        accessory: AnyView(StatusPill(text: "\(vm.estimates.count)", color: .secondary))) {
            VStack(spacing: 8) {
                ForEach(Array(vm.estimates.prefix(80))) { estimate in
                    HStack(spacing: 10) {
                        Image(systemName: "location.circle")
                            .foregroundStyle(confidenceColor(estimate)).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(estimate.displaySSID).font(.subheadline).fontWeight(.medium).lineLimit(1)
                            Text(estimate.bssid).font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("±\(Int(estimate.radiusMeters.rounded())) m").font(.caption).monospacedDigit()
                            Text("\(estimate.confidence.label) · \(estimate.observationCount)x")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).fontWeight(.bold).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func confidenceColor(_ estimate: WiFiMapperAPEstimate) -> Color {
        switch estimate.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}
