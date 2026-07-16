import SwiftUI
import Combine

/// Accumulates passive survey rows and explicit session boundaries relayed by
/// TumoSurvey over App Bridge v2.
@MainActor
final class LiveMarauderViewModel: ObservableObject {
    @Published private(set) var result = MarauderParseResult()
    @Published private(set) var linesReceived = 0
    @Published private(set) var lastLineAt: Date?
    @Published private(set) var session = TumoSurveySessionState()

    private let ble: FlipperBLE
    private var cancellable: AnyCancellable?

    init(ble: FlipperBLE = .shared) {
        self.ble = ble
    }

    func start() {
        guard cancellable == nil else { return }
        cancellable = ble.appBridgeIn
            .filter {
                $0.appID == "wifi_mapper" &&
                TumoSurveySessionState.accepts(command: $0.command)
            }
            .sink { [weak self] frame in self?.handle(frame) }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }

    func clear() {
        result = MarauderParseResult()
        linesReceived = 0
        lastLineAt = nil
    }

    private func handle(_ frame: AppBridgeFrame) {
        let transition = session.apply(command: frame.command, payload: frame.payload)
        if transition == .started {
            clear()
            return
        }
        guard transition == .data else { return }
        guard let text = String(data: frame.payload, encoding: .utf8), !text.isEmpty else { return }
        let chunk = MarauderLogParser.parse(text)
        result = MarauderParseResult.aggregate([result, chunk])
        linesReceived += chunk.rawLines
        lastLineAt = Date()
    }
}

/// Live scan tab (issue #6): shows APs/stations updating in real time from the Flipper's
/// TumoSurvey live relay, entirely separate from the offline pcap/log analysis flow —
/// `MarauderView`'s own state and cached aggregate are untouched by this screen.
struct MarauderLiveView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var live = LiveMarauderViewModel()

    var body: some View {
        CardScroll {
            statusCard
            if live.result.aps.isEmpty && live.result.unassociatedStations.isEmpty {
                emptyCard
            } else {
                if !live.result.aps.isEmpty { marauderNetworksCard(live.result) }
                if !live.result.unassociatedStations.isEmpty { marauderOtherClientsCard(live.result) }
            }
        }
        .navigationTitle("Live Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { live.clear() } label: { Image(systemName: "trash") }
                    .disabled(live.linesReceived == 0)
            }
        }
        .task { live.start() }
        .onDisappear { live.stop() }
    }

    private var statusCard: some View {
        SectionCard(title: "TumoSurvey Live", systemImage: "dot.radiowaves.left.and.right",
                    accessory: AnyView(StatusPill(
                        text: ble.appBridgeV2 ? "App Bridge v2" : "No bridge",
                        color: ble.appBridgeV2 ? .green : .orange,
                        systemImage: "antenna.radiowaves.left.and.right"))) {
            if !ble.appBridgeV2 {
                Label("App Bridge v2 is unavailable for this firmware.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let last = live.lastLineAt {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Receiving — last line").font(.caption).foregroundStyle(.secondary)
                    Text(last, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Text("ago").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(live.linesReceived) lines · \(live.result.aps.count) networks · \(live.result.stations.count) clients")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Label(live.session.isActive ? "Survey active — waiting for access points." : "Waiting for an active survey.",
                      systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyCard: some View {
        Text("No networks observed in this session.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .card()
    }
}
