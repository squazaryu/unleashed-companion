import SwiftUI
import Combine

@MainActor
final class BridgeViewModel: ObservableObject {
    @Published var customAppID = "sber_relay"
    @Published var customCommand = "toggle"
    @Published var customPayload = ""

    func send(appID: String, command: String, payload: String = "") {
        FlipperBLE.shared.sendAppBridge(appID: appID, command: command,
                                        payload: Data(payload.utf8))
    }
}

// MARK: - Relay (main: control + status only)

struct BridgeView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var relay: RelayExecutor

    var body: some View {
        // Stack-agnostic: pushed inside Home's NavigationStack (Relay is no longer a tab).
        Group {
            CardScroll {
                controlCard
                if !ble.supportsAppBridge && ble.state == .ready { appBridgeWarning }
            }
            .navigationTitle("Relay")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { RelaySettingsView() } label: { Image(systemName: "gearshape") }
                }
            }
        }
    }

    private var controlCard: some View {
        SectionCard(title: "Relay", systemImage: "switch.2",
                    accessory: AnyView(statePill)) {
            HStack(spacing: 10) {
                PillButton(title: "On", systemImage: "power", tint: .green) { relay.test(action: "on") }
                PillButton(title: "Off", systemImage: "poweroff", tint: .secondary) { relay.test(action: "off") }
                PillButton(title: "Toggle", systemImage: "arrow.triangle.2.circlepath") { relay.test(action: "toggle") }
            }
            HStack(spacing: 8) {
                StatusPill(text: relay.enabled ? "Bridge on" : "Bridge off",
                           color: relay.enabled ? .green : .secondary)
                Text(relay.path.label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            Text("State reflects your last command and is kept across launches — the Sber relay doesn’t report a reliable live state to HA.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var statePill: some View {
        if let s = relay.relayState {
            StatusPill(text: s ? "On" : "Off", color: s ? .green : .secondary,
                       systemImage: s ? "lightbulb.fill" : "lightbulb")
        } else {
            StatusPill(text: "Unknown", color: .secondary)
        }
    }

    private var appBridgeWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("App Bridge service not detected. Enable Settings → Bluetooth → App Bridge on the Flipper.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: .orange)
    }
}

// MARK: - Relay Settings (executor, routes, HA, Sber, activity log, developer)

struct RelaySettingsView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var relay: RelayExecutor
    @ObservedObject private var haDiscovery = HomeAssistantDiscovery.shared
    @StateObject private var vm = BridgeViewModel()
    @State private var sberTokenInput = ""
    @State private var showSberLogin = false
    @State private var showManualToken = false
    @State private var showState = false

    var body: some View {
        CardScroll {
            executorCard
            haCard
            sberCard
            activityCard
            developerCard
        }
        .navigationTitle("Relay Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { haDiscovery.start() }
        .sheet(isPresented: $showSberLogin) {
            SberLoginView { ok in if ok { relay.sberLoginSucceeded() } }
        }
    }

    private var executorCard: some View {
        SectionCard(title: "Executor", systemImage: "antenna.radiowaves.left.and.right",
                    accessory: AnyView(
                        StatusPill(text: relay.enabled ? "Active" : "Off",
                                   color: relay.enabled ? .green : .secondary)
                    )) {
            Toggle("Listen for Flipper events", isOn: $relay.enabled).tint(Theme.accent)
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Route").font(.caption).foregroundStyle(.secondary)
                Picker("Route", selection: $relay.path) {
                    ForEach(RelayPath.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text("When on, this phone runs App Bridge actions from your Flipper. Auto tries the local Home Assistant webhook first, then falls back to the Sber cloud.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var haBaseIsPinned: Bool {
        !relay.haBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var haCard: some View {
        SectionCard(title: "Home Assistant", systemImage: "house.fill") {
            fieldRow("HA base URL — leave empty to auto-find", text: $relay.haBaseURL, url: true)
            if !haBaseIsPinned, let host = haDiscovery.discoveredHost {
                Label("Auto-discovered \(host)", systemImage: "house.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            Text("POST \(relay.effectiveHABase)/api/webhook/flipper_sber_relay_<cmd>")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(haBaseIsPinned
                 ? "Pinned URL. Clear it to auto-find HA over Bonjour (survives DHCP changes)."
                 : "Empty → auto-finding Home Assistant on your network (Bonjour). Or type host:port to pin it.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Read HA state (diagnostic)", isExpanded: $showState) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Optional. With a long-lived token (HA profile → Security) + entity id, “Test read state” shows what HA reports — for comparison only. The on-screen pill follows your last command, since this relay doesn’t report a reliable live state.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("HA long-lived token", text: $relay.haToken)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    fieldRow("Entity id (e.g. switch.flipper_sber_relay)", text: $relay.haEntityID, mono: true)
                    Button { Task { await relay.refreshState() } } label: {
                        Label("Test read state", systemImage: "arrow.clockwise")
                    }.font(.caption).disabled(relay.haToken.isEmpty || relay.haEntityID.isEmpty)
                }
                .padding(.top, 4)
            }
            .font(.caption).tint(.secondary)
        }
    }

    private var sberCard: some View {
        SectionCard(title: "Sber account", systemImage: "person.badge.key.fill",
                    accessory: AnyView(
                        StatusPill(text: relay.hasSberToken ? "Linked" : "Not linked",
                                   color: relay.hasSberToken ? .green : .orange,
                                   systemImage: relay.hasSberToken ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    )) {
            Button { showSberLogin = true } label: {
                Label(relay.hasSberToken ? "Re-login with Sber" : "Log in with Sber",
                      systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)

            fieldRow("Relay device_id", text: $relay.deviceID, mono: true)

            if relay.hasSberToken {
                Button("Clear token", role: .destructive) { relay.clearSberToken() }.font(.caption)
            }

            DisclosureGroup("Paste token manually", isExpanded: $showManualToken) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The `token` object from Home Assistant’s sberdevices config entry.")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextEditor(text: $sberTokenInput)
                        .frame(minHeight: 70)
                        .font(.system(.caption2, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    Button {
                        relay.importSberToken(sberTokenInput); sberTokenInput = ""
                    } label: { Label("Import token", systemImage: "key.fill") }
                        .disabled(sberTokenInput.isEmpty)
                }
                .padding(.top, 4)
            }
            .font(.caption).tint(.secondary)
        }
    }

    /// Recent failures are worth surfacing without a tap; a clean run of successes isn't.
    private var activityNeedsAttention: Bool { relay.log.prefix(3).contains { !$0.ok } }

    private var activityCard: some View {
        CollapsibleCard(title: "Activity", systemImage: "list.bullet.rectangle",
                        accessory: AnyView(activityAccessory),
                        startExpanded: activityNeedsAttention) {
            if relay.log.isEmpty {
                Text("Waiting for Flipper events…").foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(relay.log) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(e.ok ? .green : .red).font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.text).font(.system(.caption, design: .monospaced))
                                Text(e.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var activityAccessory: some View {
        if !relay.log.isEmpty {
            Text("\(relay.log.count)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var developerCard: some View {
        CollapsibleCard(title: "Developer", systemImage: "hammer.fill") {
            VStack(spacing: 10) {
                fieldRow("app_id", text: $vm.customAppID, mono: true)
                fieldRow("command", text: $vm.customCommand, mono: true)
                fieldRow("payload (optional)", text: $vm.customPayload, mono: true)
                Button {
                    vm.send(appID: vm.customAppID, command: vm.customCommand, payload: vm.customPayload)
                } label: { Label("Send raw frame", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(ble.state != .ready || vm.customAppID.isEmpty || vm.customCommand.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ placeholder: String, text: Binding<String>, mono: Bool = false, url: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .font(mono ? .system(.footnote, design: .monospaced) : .body)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .default)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
