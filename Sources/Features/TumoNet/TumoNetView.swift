import SwiftUI

@MainActor
final class TumoNetViewModel: ObservableObject {
    @Published var text = ""
    @Published var route: TumoNetRoute = .inbox
    @Published private(set) var capabilities: TumoNetCapabilities?
    @Published private(set) var gatewayStatus: TumoNetStatus?
    @Published private(set) var lastReceipt: TumoNetReceipt?
    @Published private(set) var lastEnvelope: TumoNetEnvelope?
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?

    private static let sourceKey = "tumonet.source-id"
    private let sourceID: UInt32

    init(defaults: UserDefaults = .standard) {
        let saved = UInt32(defaults.string(forKey: Self.sourceKey) ?? "", radix: 16)
        let generated = UInt32.random(in: 1...UInt32.max)
        sourceID = saved.flatMap { $0 == 0 ? nil : $0 } ?? generated
        defaults.set(TumoNetCodec.hex(sourceID), forKey: Self.sourceKey)
    }

    var textBytes: Int { text.utf8.count }
    var messageValid: Bool {
        !text.isEmpty && textBytes <= TumoNetEnvelope.textLimit &&
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    var canRetry: Bool { lastEnvelope != nil && !busy }
    var sourceLabel: String { TumoNetCodec.hex(sourceID) }

    func refresh(_ ble: FlipperBLE) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            capabilities = try await ble.tumonetCapabilities()
            gatewayStatus = try await ble.tumonetStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(_ ble: FlipperBLE) async {
        guard messageValid, !busy else { return }
        var messageID = UInt32.random(in: 1...UInt32.max)
        if messageID == lastEnvelope?.messageID { messageID = messageID &+ 1 }
        if messageID == 0 { messageID = 1 }
        let envelope = TumoNetEnvelope(
            route: route, sourceID: sourceID, messageID: messageID, text: text)
        await send(envelope, through: ble)
    }

    func retry(_ ble: FlipperBLE) async {
        guard let lastEnvelope, !busy else { return }
        await send(lastEnvelope, through: ble)
    }

    private func send(_ envelope: TumoNetEnvelope, through ble: FlipperBLE) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            lastEnvelope = envelope
            lastReceipt = try await ble.tumonetSend(envelope)
            gatewayStatus = try await ble.tumonetStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TumoNetView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var model = TumoNetViewModel()

    private var linkReady: Bool { ble.state == .ready && ble.appBridgeV2 }

    var body: some View {
        CardScroll {
            gatewayCard
            composeCard
            if let receipt = model.lastReceipt { receiptCard(receipt) }
            if let error = model.errorMessage { errorCard(error) }
        }
        .navigationTitle("TumoNet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refresh(ble) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.busy || !linkReady)
                .accessibilityLabel("Refresh TumoNet status")
            }
        }
        .task(id: linkReady) {
            guard linkReady else { return }
            await model.refresh(ble)
        }
    }

    private var gatewayCard: some View {
        SectionCard(
            title: "Gateway",
            systemImage: "point.3.connected.trianglepath.dotted",
            accessory: AnyView(connectionPill)) {
            infoRow("Link", value: linkReady ? "FAB2" : "Offline")
            infoRow("Gateway", value: model.gatewayStatus?.active == true ? "Active" : "Stopped")
            infoRow("Inbox", value: String(model.gatewayStatus?.inboxCount ?? 0))
            infoRow("Duplicates", value: String(model.gatewayStatus?.duplicateCount ?? 0))
            if let status = model.gatewayStatus {
                infoRow("Last route", value: "\(status.ingress) -> \(status.route)")
                infoRow("Result", value: status.status)
            }
        }
    }

    private var composeCard: some View {
        SectionCard(title: "Message", systemImage: "paperplane") {
            Picker("Route", selection: $model.route) {
                ForEach(TumoNetRoute.allCases) { route in Text(route.title).tag(route) }
            }
            .pickerStyle(.segmented)

            TextField("Message", text: $model.text, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.sentences)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("Source \(model.sourceLabel)")
                Spacer()
                Text("\(model.textBytes)/\(TumoNetEnvelope.textLimit) bytes")
                    .foregroundStyle(model.textBytes > TumoNetEnvelope.textLimit ? .red : .secondary)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                PillButton(title: "Retry", systemImage: "arrow.clockwise", tint: .blue) {
                    Task { await model.retry(ble) }
                }
                .disabled(!model.canRetry || !linkReady)
                .opacity(model.canRetry && linkReady ? 1 : 0.4)

                PillButton(title: "Send", systemImage: "paperplane.fill", tint: .orange) {
                    Task { await model.send(ble) }
                }
                .disabled(!model.messageValid || model.busy || !linkReady || model.gatewayStatus?.active != true)
                .opacity(model.messageValid && !model.busy && linkReady && model.gatewayStatus?.active == true ? 1 : 0.4)
            }
        }
    }

    private func receiptCard(_ receipt: TumoNetReceipt) -> some View {
        SectionCard(
            title: "Delivery",
            systemImage: "checkmark.seal",
            accessory: AnyView(StatusPill(
                text: receipt.result == .delivered ? "Delivered" : "Duplicate",
                color: receipt.result == .delivered ? .green : .blue))) {
            infoRow("Message", value: TumoNetCodec.hex(receipt.messageID))
            infoRow("Route", value: receipt.route)
            infoRow("Identity", value: TumoNetCodec.hex(receipt.sourceID))
        }
    }

    @ViewBuilder private var connectionPill: some View {
        if model.busy {
            ProgressView().controlSize(.small)
        } else if !linkReady {
            StatusPill(text: "Offline", color: .secondary)
        } else if model.gatewayStatus?.active == true {
            StatusPill(text: "Active", color: .green, systemImage: "checkmark.circle.fill")
        } else {
            StatusPill(text: "Stopped", color: .orange)
        }
    }

    private func errorCard(_ message: String) -> some View {
        SectionCard(title: "Failure", systemImage: "exclamationmark.triangle") {
            Text(message).foregroundStyle(.red)
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.subheadline, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }
}
