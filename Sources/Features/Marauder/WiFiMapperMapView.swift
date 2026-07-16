import Foundation
import MapKit
import SwiftUI

struct WiFiMapperPoint: Identifiable, Equatable {
    let id: String
    let sourceName: String
    let ssid: String
    let bssid: String
    let auth: String
    let channel: Int?
    let rssi: Int?
    let bestRSSI: Int?
    let lastRSSI: Int?
    let averageRSSI: Int?
    let samples: Int?
    let tickMS: Int?
    let firstTickMS: Int?
    let lastTickMS: Int?
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let accuracy: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displaySSID: String { ssid.isEmpty ? "<hidden>" : ssid }
    var primaryRSSI: Int? { bestRSSI ?? rssi ?? lastRSSI ?? averageRSSI }
    var isCleanExport: Bool { samples != nil }
}

enum WiFiMapperGeoJSONParser {
    enum ParserError: LocalizedError {
        case invalidFeatureCollection

        var errorDescription: String? {
            switch self {
            case .invalidFeatureCollection:
                return "GeoJSON does not contain a valid FeatureCollection."
            }
        }
    }

    static func parse(_ data: Data, sourceName: String = "export.geojson") throws -> [WiFiMapperPoint] {
        let collection = try JSONDecoder().decode(FeatureCollection.self, from: data)
        guard collection.type == "FeatureCollection" else {
            throw ParserError.invalidFeatureCollection
        }

        return collection.features.enumerated().compactMap { index, feature in
            guard feature.geometry.type == "Point",
                  feature.geometry.coordinates.count >= 2
            else { return nil }

            let lon = feature.geometry.coordinates[0]
            let lat = feature.geometry.coordinates[1]
            guard isValidCoordinate(latitude: lat, longitude: lon) else { return nil }

            let props = FeatureProperties(feature.properties)
            let bssid = props.string("bssid")?.uppercased() ?? ""
            let tickMS = props.int("tick_ms")
            let firstTickMS = props.int("first_tick_ms")
            let stableSuffix = tickMS ?? firstTickMS ?? index

            return WiFiMapperPoint(
                id: "\(sourceName)|\(bssid.isEmpty ? "point" : bssid)|\(stableSuffix)|\(index)",
                sourceName: sourceName,
                ssid: props.string("ssid") ?? "",
                bssid: bssid,
                auth: props.string("auth") ?? "",
                channel: props.int("channel"),
                rssi: props.int("rssi"),
                bestRSSI: props.int("best_rssi"),
                lastRSSI: props.int("last_rssi"),
                averageRSSI: props.int("avg_rssi"),
                samples: props.int("samples"),
                tickMS: tickMS,
                firstTickMS: firstTickMS,
                lastTickMS: props.int("last_tick_ms"),
                latitude: lat,
                longitude: lon,
                altitude: feature.geometry.coordinates.count > 2 ? feature.geometry.coordinates[2] : nil,
                accuracy: props.double("accuracy"))
        }
    }

    private static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            return false
        }

        // ESP32/Marauder uses 0/0 as "GPS has no fix"; do not map it as a real point.
        return abs(latitude) >= 0.000001 || abs(longitude) >= 0.000001
    }
}

@MainActor
final class WiFiMapperMapViewModel: ObservableObject {
    @Published var exports: [FlipperFile] = []
    @Published var selectedPath: String?
    @Published var points: [WiFiMapperPoint] = []
    @Published var minimumRSSI: Double = -100
    @Published var loading = false
    @Published var status: String?

    private let storage: FlipperStorage
    private let exportDirectory = "/ext/apps_data/wifi_mapper/exports"

    init(storage: FlipperStorage = FlipperStorage()) {
        self.storage = storage
    }

    var selectedFileName: String {
        exports.first { $0.path == selectedPath }?.name ?? "No export selected"
    }

    var filteredPoints: [WiFiMapperPoint] {
        points.filter { point in
            guard let rssi = point.primaryRSSI else { return true }
            return Double(rssi) >= minimumRSSI
        }
    }

    var estimatedAccessPoints: [WiFiMapperAPEstimate] {
        WiFiMapperAPEstimator.estimates(from: filteredPoints)
    }

    var cleanCount: Int { points.filter(\.isCleanExport).count }

    func refresh() async {
        loading = true
        defer { loading = false }

        do {
            let files = try await storage.list(exportDirectory)
            exports = files
                .filter { !$0.isDirectory && $0.name.lowercased().hasSuffix(".geojson") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }

            guard let first = exports.first else {
                selectedPath = nil
                points = []
                status = "No TumoSurvey GeoJSON exports found."
                return
            }

            if selectedPath == nil || !exports.contains(where: { $0.path == selectedPath }) {
                try await readExport(first)
            } else if points.isEmpty, let current = exports.first(where: { $0.path == selectedPath }) {
                try await readExport(current)
            }
        } catch {
            exports = []
            points = []
            selectedPath = nil
            status = "Cannot read \(exportDirectory): \(error.localizedDescription)"
        }
    }

    func load(_ file: FlipperFile, setLoading: Bool = true) async {
        if setLoading { loading = true }
        defer { if setLoading { loading = false } }

        do {
            try await readExport(file)
        } catch {
            points = []
            selectedPath = file.path
            status = "\(file.name): \(error.localizedDescription)"
        }
    }

    func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let latDelta = max((maxLat - minLat) * 1.4, 0.01)
        let lonDelta = max((maxLon - minLon) * 1.4, 0.01)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }

    private func readExport(_ file: FlipperFile) async throws {
        let data = try await storage.read(file.path)
        points = try WiFiMapperGeoJSONParser.parse(data, sourceName: file.name)
        selectedPath = file.path
        let exportType = points.first?.isCleanExport == true ? "clean" : "raw"
        status = "\(file.name) - \(exportType) - \(points.count) point\(points.count == 1 ? "" : "s")"
    }
}

private enum WiFiMapperMapLayer: String, CaseIterable, Identifiable {
    case observations
    case estimates
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .observations: return "Seen"
        case .estimates: return "APs"
        case .both: return "Both"
        }
    }

    var showsObservations: Bool { self == .observations || self == .both }
    var showsEstimates: Bool { self == .estimates || self == .both }
}

struct WiFiMapperMapView: View {
    @StateObject private var vm = WiFiMapperMapViewModel()
    @State private var position: MapCameraPosition = .automatic
    @State private var mapLayer: WiFiMapperMapLayer = .both

    var body: some View {
        CardScroll {
            controlsCard
            if vm.filteredPoints.isEmpty {
                emptyCard
            } else {
                mapCard
                if !vm.estimatedAccessPoints.isEmpty {
                    estimatedAccessPointsCard
                }
                networksCard
            }
        }
        .navigationTitle("Saved Survey Maps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(vm.loading)
            }
        }
        .task { await refresh() }
        .onChange(of: vm.filteredPoints) { _, _ in updateMapRegion() }
    }

    private var controlsCard: some View {
        SectionCard(title: "Mapper exports", systemImage: "map") {
            if vm.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading exports...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !vm.exports.isEmpty {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.selectedFileName)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let status = vm.status {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Menu {
                        ForEach(vm.exports) { file in
                            Button(file.name) {
                                Task {
                                    await vm.load(file)
                                    updateMapRegion()
                                }
                            }
                        }
                    } label: {
                        Label("Export", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                }

                Divider().opacity(0.4)

                HStack {
                    Text("Min RSSI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $vm.minimumRSSI, in: -100 ... -30, step: 1)
                    Text("\(Int(vm.minimumRSSI))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }

                HStack {
                    statTile("\(vm.filteredPoints.count)", "shown")
                    statTile("\(vm.points.count)", "total")
                    statTile("\(vm.cleanCount)", "clean")
                    statTile("\(vm.estimatedAccessPoints.count)", "AP est.")
                }

                Picker("Map layer", selection: $mapLayer) {
                    ForEach(WiFiMapperMapLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mapLayer) { _, _ in updateMapRegion() }
            } else if let status = vm.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyCard: some View {
        SectionCard(title: "No map points", systemImage: "mappin.slash") {
            Text("No saved survey maps.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mapCard: some View {
        SectionCard(title: "Map", systemImage: "location") {
            Map(position: $position) {
                if mapLayer.showsEstimates {
                    ForEach(vm.estimatedAccessPoints) { estimate in
                        MapCircle(center: estimate.coordinate, radius: estimate.radiusMeters)
                            .foregroundStyle(confidenceColor(estimate).opacity(0.10))
                            .stroke(confidenceColor(estimate).opacity(0.35), lineWidth: 1)
                    }

                    ForEach(vm.estimatedAccessPoints) { estimate in
                        Annotation(estimate.displaySSID, coordinate: estimate.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(confidenceColor(estimate).opacity(0.20))
                                    .frame(width: 34, height: 34)
                                Image(systemName: "location.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(confidenceColor(estimate))
                                    .background(.regularMaterial, in: Circle())
                            }
                        }
                    }
                }

                if mapLayer.showsObservations {
                    ForEach(vm.filteredPoints) { point in
                        Annotation(point.displaySSID, coordinate: point.coordinate) {
                            ZStack {
                                Circle()
                                    .fill(signalColor(point).opacity(0.22))
                                    .frame(width: 30, height: 30)
                                Image(systemName: "wifi.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(signalColor(point))
                                    .background(.regularMaterial, in: Circle())
                            }
                        }
                    }
                }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var estimatedAccessPointsCard: some View {
        CollapsibleCard(title: "Estimated APs", systemImage: "location.circle",
                        accessory: AnyView(StatusPill(text: "\(vm.estimatedAccessPoints.count)", color: .secondary))) {
            VStack(spacing: 8) {
                ForEach(Array(vm.estimatedAccessPoints.prefix(80))) { estimate in
                    HStack(spacing: 10) {
                        Image(systemName: "location.circle")
                            .foregroundStyle(confidenceColor(estimate))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(estimate.displaySSID)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(estimate.bssid)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(estimate.radiusMeters.rounded())) m")
                                .font(.caption)
                                .monospacedDigit()
                            Text("\(estimate.confidence.label) · \(estimate.observationCount)x")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.25)
                }

                if vm.estimatedAccessPoints.count > 80 {
                    Text("Showing first 80 estimated APs.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var networksCard: some View {
        CollapsibleCard(title: "Networks", systemImage: "wifi",
                        accessory: AnyView(StatusPill(text: "\(vm.filteredPoints.count)", color: .secondary))) {
            VStack(spacing: 8) {
                ForEach(Array(vm.filteredPoints.prefix(120))) { point in
                    HStack(spacing: 10) {
                        Image(systemName: "wifi")
                            .foregroundStyle(signalColor(point))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.displaySSID)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(point.bssid.isEmpty ? point.sourceName : point.bssid)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let rssi = point.primaryRSSI {
                                Text("\(rssi) dBm")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            if let channel = point.channel {
                                Text("ch \(channel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider().opacity(0.25)
                }

                if vm.filteredPoints.count > 120 {
                    Text("Showing first 120 networks. Raise the RSSI filter to narrow the map.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func signalColor(_ point: WiFiMapperPoint) -> Color {
        guard let rssi = point.primaryRSSI else { return .secondary }
        if rssi >= -55 { return .green }
        if rssi >= -70 { return .orange }
        return .red
    }

    private func confidenceColor(_ estimate: WiFiMapperAPEstimate) -> Color {
        switch estimate.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    private func refresh() async {
        await vm.refresh()
        updateMapRegion()
    }

    private func updateMapRegion() {
        var coordinates: [CLLocationCoordinate2D] = []
        if mapLayer.showsObservations {
            coordinates.append(contentsOf: vm.filteredPoints.map(\.coordinate))
        }
        if mapLayer.showsEstimates {
            coordinates.append(contentsOf: vm.estimatedAccessPoints.map(\.coordinate))
        }

        guard let region = vm.region(for: coordinates) else {
            position = .automatic
            return
        }
        position = .region(region)
    }
}

private struct FeatureCollection: Decodable {
    let type: String
    let features: [Feature]
}

private struct Feature: Decodable {
    let geometry: Geometry
    let properties: [String: GeoJSONValue]
}

private struct Geometry: Decodable {
    let type: String
    let coordinates: [Double]
}

private struct FeatureProperties {
    let values: [String: GeoJSONValue]

    init(_ values: [String: GeoJSONValue]) {
        self.values = values
    }

    func string(_ key: String) -> String? { values[key]?.stringValue }
    func int(_ key: String) -> Int? { values[key]?.intValue }
    func double(_ key: String) -> Double? { values[key]?.doubleValue }
}

private enum GeoJSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .string(let value): return Int(value)
        case .number(let value): return Int(value)
        case .bool, .null: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .string(let value): return Double(value)
        case .number(let value): return value
        case .bool, .null: return nil
        }
    }
}
