import Foundation
import SwiftUI
import WidgetKit
import UnleashedShared

@MainActor
final class DeviceInfoViewModel: ObservableObject {
    @Published var info: [(String, String)] = []
    @Published var power: [(String, String)] = []
    @Published var loading = false
    @Published var error: String?

    private let system = FlipperSystem()

    /// Clears everything cached from the previous connection. Without this, the
    /// `vm.info.isEmpty` / `vm.runtimeStatus == nil` reload guards would keep showing
    /// a prior Flipper's info after disconnecting and connecting to a different one.
    func reset() {
        info = []; power = []; error = nil
        runtimeStatus = nil; runtimeTwin = nil; runtimeTrace = nil; runtimeError = nil
    }

    private var dict: [String: String] {
        Dictionary(info, uniquingKeysWith: { a, _ in a })
            .merging(Dictionary(power, uniquingKeysWith: { a, _ in a }), uniquingKeysWith: { a, _ in a })
    }

    func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            async let i = system.deviceInfo()
            async let p = system.powerInfo()
            info = try await i
            power = try await p
            mirrorToWidgets()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fill in firmware + device name for the Flipper-status widget, preserving the
    /// live connection/battery fields written elsewhere.
    private func mirrorToWidgets() {
        let prev = SharedStore.flipper()
        SharedStore.saveFlipper(.init(
            connected: prev?.connected ?? true,
            battery: prev?.battery,
            firmware: value("firmware_version") ?? "",
            name: value("hardware_name") ?? "Flipper",
            updated: Date()))
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Curated summary

    func value(_ key: String) -> String? {
        let v = dict[key]
        return (v?.isEmpty == false) ? v : nil
    }

    var model: String {
        let name = value("hardware_name") ?? "Flipper"
        let ver = value("hardware_ver").map { " v\($0)" } ?? ""
        return name + ver
    }

    var firmware: String? {
        // e.g. "Unleashed 1.3.4 (a1b2c3d, 2026-06-01)"
        let origin = value("firmware_origin_fork") ?? value("firmware_origin") ?? value("firmware_branch")
        let ver = value("firmware_version")
        let commit = value("firmware_commit")
        let date = value("firmware_build_date")
        var parts: [String] = []
        if let origin { parts.append(origin) }
        if let ver, ver != origin { parts.append(ver) }
        var head = parts.joined(separator: " ")
        var tail: [String] = []
        if let commit { tail.append(commit) }
        if let date { tail.append(date) }
        if !tail.isEmpty { head += " (\(tail.joined(separator: ", ")))" }
        return head.isEmpty ? nil : head
    }

    var region: String? { value("hardware_region_provisioned") ?? value("hardware_region") }

    var radio: String? {
        guard let major = value("radio_stack_major"), let minor = value("radio_stack_minor") else {
            return value("radio_stack_type")
        }
        let type = value("radio_stack_type").map { " (type \($0))" } ?? ""
        return "\(major).\(minor)\(type)"
    }

    var battery: String? {
        guard let lvl = value("charge_level") else { return nil }
        var s = "\(lvl)%"
        if let temp = value("temp_gauge") ?? value("temp_charge") { s += " · \(temp)°C" }
        if let v = value("voltage_gauge") ?? value("voltage_vbus") { s += " · \(v) V" }
        return s
    }

    var batteryHealth: String? { value("health").map { "\($0)%" } }

    // MARK: - Runtime diagnostics (FAB2 `runtime/status`, `/trace`, `/twin`)

    @Published var runtimeStatus: RuntimeStatus?
    @Published var runtimeTwin: RuntimeTwin?
    @Published var runtimeTrace: RuntimeTrace?
    @Published var runtimeLoading = false
    @Published var runtimeError: String?

    /// Best-effort: `status` is the primary read (surfaced on failure), `twin`/`trace`
    /// are supplementary and only attempted when the negotiated capabilities advertise
    /// them — silently absent rather than shown as errors if they don't come back.
    func loadRuntimeDiagnostics(_ ble: FlipperBLE) async {
        guard ble.appBridgeV2 else { return }
        runtimeLoading = true; runtimeError = nil
        defer { runtimeLoading = false }
        do {
            runtimeStatus = try await ble.runtimeStatus()
        } catch {
            runtimeError = error.localizedDescription
        }
        let caps = RuntimeCapabilities(ble.appBridgeCapabilities)
        if caps.supportsTwin { runtimeTwin = try? await ble.runtimeTwin() }
        if caps.supportsTrace { runtimeTrace = try? await ble.runtimeTrace() }
    }
}

/// Device-information screen mirroring the official app: a curated summary
/// (model, firmware, region, radio stack, battery) plus the full raw key/value
/// dump from `device_info` and `power_info`.
struct DeviceInfoView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = DeviceInfoViewModel()

    var body: some View {
        Group {
            if ble.state != .ready {
                ContentUnavailableView("Not connected", systemImage: "questionmark.app.dashed",
                    description: Text("Connect to a Flipper on the Device tab."))
            } else {
                CardScroll {
                    if let error = vm.error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(tint: .orange)
                    }

                    SectionCard(title: "Device", systemImage: "cpu") {
                        infoRow("Model", vm.model)
                        if let fw = vm.firmware { infoRow("Firmware", fw) }
                        if let r = vm.region { infoRow("Region", r) }
                        if let radio = vm.radio { infoRow("Radio stack", radio) }
                        if let uid = vm.value("hardware_uid") { infoRow("UID", uid) }
                    }

                    SectionCard(title: "Battery", systemImage: "battery.100") {
                        if let b = vm.battery { infoRow("Charge", b) }
                        if let h = vm.batteryHealth { infoRow("Health", h) }
                        if vm.battery == nil && !vm.loading {
                            Text("No power data").foregroundStyle(.secondary).font(.footnote)
                        }
                    }

                    if ble.appBridgeV2 { runtimeDiagnosticsCard }

                    CollapsibleCard(title: "All properties (\(vm.info.count + vm.power.count))",
                                    systemImage: "list.bullet.rectangle") {
                        let all = vm.info + vm.power
                        VStack(spacing: 6) {
                            ForEach(Array(all.enumerated()), id: \.offset) { _, kv in
                                rawRow(kv.0, kv.1)
                            }
                        }
                    }
                }
                .overlay { if vm.loading && vm.info.isEmpty { ProgressView() } }
                .refreshable { await vm.load() }
            }
        }
        .navigationTitle("Device info")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ble.state) {
            guard ble.state == .ready else {
                // Disconnected (possibly to reconnect to a DIFFERENT Flipper) — drop
                // cached info so the reload guards below fire again once ready.
                vm.reset()
                return
            }
            if vm.info.isEmpty { await vm.load() }
            if vm.runtimeStatus == nil { await vm.loadRuntimeDiagnostics(ble) }
        }
    }

    /// Read-only FAB2 Runtime diagnostics (issue #15): firmware/commit/dirty, API/
    /// target, SD + package-state readiness, bridge session/owner, radio state, and
    /// (where the firmware advertises them) live battery % and a recent trace ring —
    /// collapsed by default since this is diagnostic detail, not primary device info.
    private var runtimeDiagnosticsCard: some View {
        CollapsibleCard(title: "Runtime", systemImage: "bolt.horizontal.circle",
                        accessory: AnyView(runtimeAccessory)) {
            if let error = vm.runtimeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let status = vm.runtimeStatus {
                if let fw = status.firmwareVersion { infoRow("Firmware", fw) }
                if let commit = status.commit {
                    infoRow("Commit", status.dirty == true ? "\(commit) (dirty)" : commit)
                }
                if let api = status.api, let target = status.target {
                    infoRow("API / target", "\(api) / f\(target)")
                }
                if let sd = status.sdReady {
                    infoRow("SD card", sd ? "Ready" : "Not ready")
                }
                if let pkg = status.packageStatePresent {
                    infoRow("Package state", pkg ? "Present" : "Not installed")
                }
                if let twin = vm.runtimeTwin {
                    if let bat = twin.batteryPercent {
                        infoRow("Battery (twin)", "\(bat)%")
                    }
                    if let charging = twin.charging {
                        infoRow("Charging", charging ? "Yes" : "No")
                    }
                    if let otg = twin.otgEnabled {
                        infoRow("OTG", otg ? "Enabled" : "Disabled")
                    }
                    if let heap = twin.maxHeapBlock {
                        infoRow("Max heap block", formatBytes(heap))
                    }
                }
                if let radio = status.radioStateLabel {
                    infoRow("Radio", radio)
                }
                if let sid = status.sessionID {
                    infoRow("Bridge session", sid == "00000000" ? "None" : sid)
                }
                if let owner = status.bridgeOwner, !owner.isEmpty {
                    infoRow("Bridge owner", owner)
                }
            } else if !vm.runtimeLoading {
                Text("Tap refresh to fetch Runtime diagnostics.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let trace = vm.runtimeTrace, !trace.entries.isEmpty {
                Divider().opacity(0.4)
                Text("RECENT ACTIVITY").font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.secondary).tracking(0.5)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(trace.entries) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.ok ? "checkmark.circle" : "xmark.circle")
                                .font(.caption2)
                                .foregroundStyle(entry.ok ? Color.secondary : Color.orange)
                            Text("\(entry.codeLabel) · \(entry.command)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            PillButton(title: "Refresh", systemImage: "arrow.clockwise", tint: .secondary) {
                Task { await vm.loadRuntimeDiagnostics(ble) }
            }
            .disabled(vm.runtimeLoading)
        }
    }

    @ViewBuilder private var runtimeAccessory: some View {
        if vm.runtimeLoading {
            ProgressView().scaleEffect(0.8)
        } else if let sid = vm.runtimeStatus?.sessionID, sid != "00000000" {
            StatusPill(text: "Session", color: .green, systemImage: "checkmark.circle.fill")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func rawRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.caption2, design: .monospaced))
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
