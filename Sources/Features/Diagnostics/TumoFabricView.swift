import SwiftUI

@MainActor
final class TumoFabricViewModel: ObservableObject {
    struct StepAttempt: Equatable {
        let sequence: UInt32
        let operation: TumoFabricOperation
    }

    @Published private(set) var capabilities: TumoFabricCapabilities?
    @Published private(set) var fabricState: TumoFabricState?
    @Published private(set) var busy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastAttempt: StepAttempt?
    @Published private(set) var lastWasDuplicate = false

    private static let sidKey = "tumofabric.counter.sid"
    private static let tokenKey = "tumofabric.counter.token"
    private var sessionID: UInt32?
    private var token: UInt32?
    private var discoveryInFlight = false

    init(defaults: UserDefaults = .standard) {
        sessionID = TumoFabricCodec.hex32(defaults.string(forKey: Self.sidKey))
        token = TumoFabricCodec.hex32(defaults.string(forKey: Self.tokenKey))
    }

    var hasSavedSession: Bool { sessionID != nil && token != nil }
    var canMutate: Bool { fabricState != nil && !busy }

    func startOrResume(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        while discoveryInFlight {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }

        do {
            capabilities = try await ble.fabricCapabilities()
            let currentToken = token ?? UInt32.random(in: 1...UInt32.max)
            let state = try await ble.fabricOpen(owner: "iphone", token: currentToken)
            apply(state, defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeAfterReconnect(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        await attachIfAvailable(ble, defaults: defaults)
    }

    func attachIfAvailable(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        guard fabricState == nil, !busy, !discoveryInFlight else { return }
        discoveryInFlight = true
        defer { discoveryInFlight = false }

        do {
            let discovered = try await ble.fabricCapabilities()
            capabilities = discovered
            guard discovered.allowsAutomaticAttach(hasSavedSession: hasSavedSession) else { return }

            errorMessage = nil
            busy = true
            defer { busy = false }
            let currentToken = token ?? UInt32.random(in: 1...UInt32.max)
            let state = try await ble.fabricOpen(owner: "iphone", token: currentToken)
            apply(state, defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        guard let sessionID, let token, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            let state = try await ble.fabricState(sessionID: sessionID, token: token)
            apply(state, defaults: defaults)
        } catch {
            handle(error, defaults: defaults)
        }
    }

    func step(_ operation: TumoFabricOperation, ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        guard let state = fabricState, !busy else { return }
        let attempt = StepAttempt(sequence: state.sequence &+ 1, operation: operation)
        await send(attempt, ble: ble, defaults: defaults)
    }

    func replayLast(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        guard let attempt = lastAttempt, !busy else { return }
        await send(attempt, ble: ble, defaults: defaults)
    }

    func cancel(_ ble: FlipperBLE, defaults: UserDefaults = .standard) async {
        guard let sessionID, let token, !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            try await ble.fabricCancel(sessionID: sessionID, token: token)
            clear(defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func send(_ attempt: StepAttempt, ble: FlipperBLE, defaults: UserDefaults) async {
        guard let sessionID, let token else { return }
        busy = true
        errorMessage = nil
        lastAttempt = attempt
        defer { busy = false }
        do {
            let state = try await ble.fabricStep(
                sessionID: sessionID,
                token: token,
                sequence: attempt.sequence,
                operation: attempt.operation)
            apply(state, defaults: defaults)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ state: TumoFabricState, defaults: UserDefaults) {
        sessionID = state.sessionID
        token = state.token
        fabricState = state
        lastWasDuplicate = state.duplicate
        defaults.set(TumoFabricCodec.hex(state.sessionID), forKey: Self.sidKey)
        defaults.set(TumoFabricCodec.hex(state.token), forKey: Self.tokenKey)
    }

    private func clear(defaults: UserDefaults) {
        sessionID = nil
        token = nil
        fabricState = nil
        capabilities = nil
        lastAttempt = nil
        lastWasDuplicate = false
        defaults.removeObject(forKey: Self.sidKey)
        defaults.removeObject(forKey: Self.tokenKey)
    }

    private func handle(_ error: Error, defaults: UserDefaults) {
        if case AppBridgeError.firmwareError("session") = error {
            clear(defaults: defaults)
            errorMessage = "The Fabric session ended on the Flipper. Start a new session to continue."
        } else {
            errorMessage = error.localizedDescription
        }
    }
}

struct TumoFabricView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = TumoFabricViewModel()

    private var fabricAdvertised: Bool {
        RuntimeCapabilities(ble.appBridgeCapabilities).supportsFabric
    }

    private var linkReady: Bool {
        ble.state == .ready && ble.appBridgeV2 && fabricAdvertised
    }

    var body: some View {
        CardScroll {
            nodeCard
            counterCard
            sessionCard
            permissionsCard
            if let error = vm.errorMessage { errorCard(error) }
        }
        .navigationTitle("TumoFabric Counter")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: ble.appBridgeV2) { _, negotiated in
            guard negotiated, fabricAdvertised else { return }
            Task { await vm.resumeAfterReconnect(ble) }
        }
        .task(id: linkReady) {
            guard linkReady else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(750))
                } catch {
                    return
                }
                if vm.fabricState != nil {
                    await vm.refresh(ble)
                } else {
                    await vm.attachIfAvailable(ble)
                }
            }
        }
    }

    private var nodeCard: some View {
        SectionCard(
            title: "Fabric node",
            systemImage: "point.3.connected.trianglepath.dotted",
            accessory: AnyView(connectionPill)) {
            infoRow("Node", value: vm.capabilities?.node.capitalized ?? "Flipper")
            infoRow("Package", value: vm.capabilities?.package ?? "counter")
            infoRow("Trust", value: "BLE bond + token")
            infoRow("Persistence", value: "RAM only")
        }
    }

    @ViewBuilder private var connectionPill: some View {
        if ble.state != .ready {
            StatusPill(text: "Offline", color: .secondary)
        } else if !ble.appBridgeV2 {
            StatusPill(text: "FAB2 unavailable", color: .orange)
        } else if !fabricAdvertised {
            StatusPill(text: "Fabric unavailable", color: .orange)
        } else {
            StatusPill(text: "Ready", color: .green, systemImage: "checkmark.circle.fill")
        }
    }

    private var counterCard: some View {
        SectionCard(title: "Counter", systemImage: "number") {
            Text(String(vm.fabricState?.value ?? 0))
                .font(.system(size: 58, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 72)

            HStack(spacing: 10) {
                PillButton(title: "Decrease", systemImage: "minus", tint: .blue) {
                    Task { await vm.step(.decrement, ble: ble) }
                }
                PillButton(title: "Increase", systemImage: "plus", tint: .green) {
                    Task { await vm.step(.increment, ble: ble) }
                }
            }
            .disabled(!vm.canMutate || !linkReady)
            .opacity(vm.canMutate && linkReady ? 1 : 0.4)
        }
    }

    private var sessionCard: some View {
        SectionCard(
            title: "Session",
            systemImage: "arrow.triangle.2.circlepath",
            accessory: vm.busy ? AnyView(ProgressView().controlSize(.small)) : nil) {
            if let state = vm.fabricState {
                infoRow("Session", value: TumoFabricCodec.hex(state.sessionID))
                infoRow("Sequence", value: String(state.sequence))
                infoRow("Last response", value: state.duplicate ? "Duplicate suppressed" : "Applied")

                HStack(spacing: 10) {
                    PillButton(title: "Refresh", systemImage: "arrow.clockwise") {
                        Task { await vm.refresh(ble) }
                    }
                    PillButton(title: "Cancel", systemImage: "xmark", role: .destructive, tint: .red) {
                        Task { await vm.cancel(ble) }
                    }
                }
                .disabled(!linkReady || vm.busy)
                .opacity(linkReady && !vm.busy ? 1 : 0.4)
                PillButton(title: "Replay last sequence", systemImage: "arrow.uturn.backward", tint: .orange) {
                    Task { await vm.replayLast(ble) }
                }
                .disabled(vm.lastAttempt == nil || vm.busy || !linkReady)
                .opacity(vm.lastAttempt == nil || vm.busy || !linkReady ? 0.4 : 1)
            } else {
                Text(vm.hasSavedSession ? "A saved session is ready to resume." : "No active Fabric session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                PillButton(
                    title: vm.hasSavedSession ? "Resume" : "Start",
                    systemImage: vm.hasSavedSession ? "arrow.clockwise" : "play.fill",
                    tint: .green) {
                    Task { await vm.startOrResume(ble) }
                }
                .disabled(!linkReady || vm.busy)
                .opacity(linkReady && !vm.busy ? 1 : 0.4)
            }
        }
    }

    private var permissionsCard: some View {
        SectionCard(title: "Data boundary", systemImage: "hand.raised.fill") {
            infoRow("Shared", value: "Counter operations")
            infoRow("Location", value: "Not requested")
            infoRow("Camera", value: "Not requested")
            infoRow("Network", value: "Not requested")
            infoRow("Remote code", value: "Not supported")
        }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: .red)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }
}
