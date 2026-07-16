import SwiftUI
import Combine

// MARK: - Contract (pure, unit-testable)

/// The two FAB2 diagnostic apps this console can drive. Both are plain App Bridge
/// v2 targets; the Terminal adds a session (`hello` → `sid`) that its
/// state-changing commands must carry.
///   • `app_bridge_terminal` — issue #16 / tumoflip#36
///   • `ble_gatt_lab`        — issue #17 / tumoflip#31
enum AppBridgeTarget: String, CaseIterable, Identifiable {
    case terminal = "app_bridge_terminal"
    case gattLab  = "ble_gatt_lab"

    var id: String { rawValue }
    var title: String { self == .terminal ? "App Bridge Terminal" : "BLE GATT Lab" }
    var usesSession: Bool { self == .terminal }

    /// Commands in the order they appear on-screen — matches each firmware contract.
    var commands: [String] {
        switch self {
        case .terminal: return ["hello", "ping", "status", "help", "echo", "emit", "release"]
        case .gattLab:  return ["ping", "status", "echo"]
        }
    }
}

/// `key=value;key=value` payload codec — the same shape the firmware uses for
/// `runtime/capabilities` and these diagnostic apps. Kept free of BLE so it's
/// unit-testable.
enum AppBridgeParams {
    static func encode(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { "\($0.0)=\($0.1)" }.joined(separator: ";").utf8)
    }

    static func decode(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in text.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        return out
    }
}

/// The command → payload rules, mirroring each firmware contract exactly.
enum AppBridgeConsoleContract {
    /// Commands that change session state and therefore must carry `sid=<hex>`
    /// (Terminal only — GATT Lab is sessionless).
    static let sessionScoped: Set<String> = ["echo", "emit", "release"]

    static func requiresSession(_ target: AppBridgeTarget, _ command: String) -> Bool {
        target.usesSession && sessionScoped.contains(command)
    }

    /// Build the outgoing payload, injecting `owner`/`sid`/`text` per the contract:
    ///   • `hello`             → `owner=iphone`
    ///   • `echo`/`emit`       → `sid=<hex>;text=<text>` (sid only when the target has a session)
    ///   • `release`           → `sid=<hex>`
    ///   • `ping`/`status`/`help` → empty
    static func payload(target: AppBridgeTarget, command: String, sid: String?, text: String) -> Data {
        var pairs: [(String, String)] = []
        switch command {
        case "hello":
            pairs.append(("owner", "iphone"))
        case "echo", "emit":
            if target.usesSession, let sid, !sid.isEmpty { pairs.append(("sid", sid)) }
            pairs.append(("text", text))
        case "release":
            if target.usesSession, let sid, !sid.isEmpty { pairs.append(("sid", sid)) }
        default:
            break   // ping / status / help carry no payload
        }
        return AppBridgeParams.encode(pairs)
    }

    /// Pull the `sid` out of a `hello` response payload.
    static func sessionID(from response: Data) -> String? {
        let sid = AppBridgeParams.decode(response)["sid"]
        return (sid?.isEmpty == false) ? sid : nil
    }
}

// MARK: - Console log model

struct AppBridgeLogEntry: Identifiable, Equatable {
    enum Kind { case tx, rx, event, error }
    let id = UUID()
    let time: Date
    let kind: Kind
    let text: String

    var icon: String {
        switch kind {
        case .tx: return "arrow.up.circle.fill"
        case .rx: return "arrow.down.circle.fill"
        case .event: return "bolt.circle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var color: Color {
        switch kind {
        case .tx: return .blue
        case .rx: return .green
        case .event: return .orange
        case .error: return .red
        }
    }
}

// MARK: - View model

@MainActor
final class AppBridgeConsoleVM: ObservableObject {
    @Published var target: AppBridgeTarget = .terminal {
        didSet { if oldValue != target { sessionID = nil } }   // sessions don't cross targets
    }
    @Published private(set) var sessionID: String?
    @Published var echoText = "test"
    @Published private(set) var log: [AppBridgeLogEntry] = []
    @Published private(set) var busy = false

    private var cancellable: AnyCancellable?

    /// Subscribe to unsolicited App Bridge events once. `FlipperBLE` routes
    /// correlated FAB2 responses to the request layer and only publishes
    /// *unsolicited* frames here, so there's no double-logging of replies.
    func attach(_ ble: FlipperBLE) {
        guard cancellable == nil else { return }
        cancellable = ble.appBridgeIn
            .receive(on: RunLoop.main)
            .sink { [weak self] frame in self?.onEvent(frame) }
    }

    private func onEvent(_ frame: AppBridgeFrame) {
        guard frame.appID == target.rawValue else { return }   // ignore other apps' events
        let body = String(data: frame.payload, encoding: .utf8) ?? "<\(frame.payload.count)B>"
        append(.event, "\(frame.command) \(body)".trimmingCharacters(in: .whitespaces))
    }

    /// True when a command can be sent right now (link ready, FAB2 up, not busy,
    /// and — for session-scoped commands — a sid is in hand).
    func canRun(_ command: String, ble: FlipperBLE) -> Bool {
        guard ble.state == .ready, ble.appBridgeV2, !busy else { return false }
        if AppBridgeConsoleContract.requiresSession(target, command) { return sessionID != nil }
        return true
    }

    func run(_ command: String, ble: FlipperBLE) {
        guard !busy else { return }
        if AppBridgeConsoleContract.requiresSession(target, command), sessionID == nil {
            append(.error, "\(command): send `hello` first — no sid yet")
            return
        }
        let payload = AppBridgeConsoleContract.payload(
            target: target, command: command, sid: sessionID, text: echoText)
        let shown = String(data: payload, encoding: .utf8) ?? ""
        append(.tx, shown.isEmpty ? command : "\(command) \(shown)")

        busy = true
        let target = self.target   // capture: the reply belongs to the target sent to
        Task {
            do {
                let data = try await ble.appBridgeRequest(
                    appID: target.rawValue, command: command, payload: payload, timeout: 6)
                let reply = String(data: data, encoding: .utf8) ?? "<\(data.count)B>"
                append(.rx, reply.isEmpty ? "(empty)" : reply)
                if command == "hello", let sid = AppBridgeConsoleContract.sessionID(from: data) {
                    sessionID = sid
                }
                if command == "release" { sessionID = nil }
            } catch {
                append(.error, "\(command): \(error.localizedDescription)")
            }
            busy = false
        }
    }

    func clear() { log.removeAll() }

    private func append(_ kind: AppBridgeLogEntry.Kind, _ text: String) {
        log.insert(AppBridgeLogEntry(time: Date(), kind: kind, text: text), at: 0)  // newest first
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}

// MARK: - View

/// Unified FAB2 diagnostic console for the `app_bridge_terminal` (issue #16) and
/// `ble_gatt_lab` (issue #17) firmware apps: pick a target, watch the FAB2
/// handshake, fire each command, and see a live tx/rx/event frame log.
struct AppBridgeConsoleView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = AppBridgeConsoleVM()

    var body: some View {
        CardScroll {
            targetCard
            if ble.state == .ready && !ble.appBridgeV2 { fab2Warning }
            commandsCard
            logCard
        }
        .navigationTitle("App Bridge Console")
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.attach(ble) }
    }

    // Target picker + FAB2 / session status.
    private var targetCard: some View {
        SectionCard(title: "Target", systemImage: "terminal",
                    accessory: AnyView(fab2Pill)) {
            Picker("Target", selection: $vm.target) {
                ForEach(AppBridgeTarget.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Text(vm.target.rawValue)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if vm.target.usesSession {
                    if let sid = vm.sessionID {
                        StatusPill(text: "sid \(sid)", color: .green, systemImage: "key.fill")
                    } else {
                        StatusPill(text: "no session", color: .secondary)
                    }
                }
            }
            Text(vm.target.usesSession
                 ? "Send `hello` to open a session; the returned sid is auto-added to echo/emit/release."
                 : "Sessionless — ping / status / echo work directly.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var fab2Pill: some View {
        if ble.state != .ready {
            StatusPill(text: "Disconnected", color: .secondary)
        } else if ble.appBridgeV2 {
            StatusPill(text: "FAB2", color: .green, systemImage: "checkmark.seal.fill")
        } else {
            StatusPill(text: "FAB1 only", color: .orange, systemImage: "exclamationmark.triangle.fill")
        }
    }

    private var fab2Warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("This console needs App Bridge v2 (FAB2). The connected firmware only negotiated FAB1 — update to a build that advertises FAB2.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: .orange)
    }

    // Command buttons + echo text.
    private var commandsCard: some View {
        SectionCard(title: "Commands", systemImage: "command") {
            if vm.target.commands.contains("echo") || vm.target.commands.contains("emit") {
                TextField("echo / emit text", text: $vm.echoText)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(vm.target.commands, id: \.self) { cmd in
                    PillButton(title: cmd, systemImage: Self.icon(for: cmd), tint: Self.tint(for: cmd)) {
                        vm.run(cmd, ble: ble)
                    }
                    .disabled(!vm.canRun(cmd, ble: ble))
                    .opacity(vm.canRun(cmd, ble: ble) ? 1 : 0.4)
                }
            }
        }
    }

    private var logCard: some View {
        SectionCard(title: "Frame log", systemImage: "list.bullet.rectangle",
                    accessory: vm.log.isEmpty ? nil : AnyView(
                        Button { vm.clear() } label: { Text("Clear").font(.caption) }
                    )) {
            if vm.log.isEmpty {
                Text(ble.state == .ready ? "Send a command to see frames." : "Connect your Flipper to begin.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.log) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: e.icon).foregroundStyle(e.color).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.text).font(.system(.caption, design: .monospaced))
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(e.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func icon(for command: String) -> String {
        switch command {
        case "hello": return "hand.wave.fill"
        case "ping": return "dot.radiowaves.left.and.right"
        case "status": return "info.circle"
        case "help": return "questionmark.circle"
        case "echo": return "arrow.left.arrow.right"
        case "emit": return "dot.radiowaves.right"
        case "release": return "xmark.circle"
        default: return "chevron.right.circle"
        }
    }

    private static func tint(for command: String) -> Color {
        switch command {
        case "hello": return .green
        case "release": return .orange
        default: return Theme.accent
        }
    }
}
