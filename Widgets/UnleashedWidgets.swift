import WidgetKit
import SwiftUI
import ActivityKit
import UnleashedShared

@main
struct UnleashedWidgetsBundle: WidgetBundle {
    // Only widgets that work WITHOUT the App Group are shipped, because Feather (the
    // user's sideload signer) doesn't register app groups, so a shared container never
    // exists. Quick Actions + relay run purely on deep links; the Install Live Activity
    // carries its data in the ActivityKit ContentState. The data-backed FlipperStatus /
    // AIRadar widgets stay in the source for signers that DO support app groups
    // (SideStore/AltStore) but are not registered here.
    var body: some Widget {
        InstallLiveActivity()
        RelayWidget()
        QuickActionsWidget()
    }
}

private let accent = Color.orange

// MARK: - Timeline

struct UnleashedEntry: TimelineEntry {
    let date: Date
    let flipper: SharedStore.FlipperStatus?
    let radar: SharedStore.RadarSnapshot?
    let relay: SharedStore.RelayInfo?
}

struct UnleashedProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnleashedEntry { Self.sample }
    func getSnapshot(in context: Context, completion: @escaping (UnleashedEntry) -> Void) {
        completion(load())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UnleashedEntry>) -> Void) {
        // The app reloads us on every data change; this is just a staleness backstop.
        let entry = load()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
    }
    private func load() -> UnleashedEntry {
        UnleashedEntry(date: Date(), flipper: SharedStore.flipper(),
                       radar: SharedStore.radar(), relay: SharedStore.relay())
    }
    static let sample = UnleashedEntry(
        date: Date(),
        flipper: .init(connected: true, battery: 82, firmware: "0.2.8", name: "TUMOFLIP", updated: Date()),
        radar: .init(providers: [
            .init(id: "claude", name: "Claude", icon: "CL", shortLabel: "Session",
                  shortUsed: 40, shortReset: "54m", weeklyUsed: 11),
            .init(id: "codex", name: "Codex", icon: "<>", shortLabel: "5h",
                  shortUsed: 55, shortReset: "15m", weeklyUsed: 24)], updatedAt: "now"),
        relay: .init(on: true, updated: Date()))
}

// MARK: - Flipper status

struct FlipperStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FlipperStatusWidget", provider: UnleashedProvider()) { entry in
            FlipperStatusView(entry: entry).widgetURL(URL(string: "unleashed://home"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Flipper status")
        .description("Battery, connection and firmware of your Flipper.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FlipperStatusView: View {
    let entry: UnleashedEntry
    var body: some View {
        let f = entry.flipper
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(accent)
                Text(f?.name.isEmpty == false ? f!.name : "Flipper").font(.headline).lineLimit(1)
                Spacer()
                Circle().fill((f?.connected == true) ? .green : .secondary).frame(width: 9, height: 9)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: batteryIcon(f?.battery)).foregroundStyle(batteryColor(f?.battery))
                Text(f?.battery.map { "\($0)%" } ?? "—").font(.system(.title2, weight: .bold)).monospacedDigit()
            }
            Text((f?.connected == true) ? "Connected" : "Offline")
                .font(.caption).foregroundStyle(.secondary)
            if let v = f?.firmware, !v.isEmpty {
                Text("fw \(v)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func batteryIcon(_ b: Int?) -> String {
        guard let b else { return "battery.0percent" }
        switch b { case ..<13: return "battery.0percent"; case ..<38: return "battery.25percent"
                   case ..<63: return "battery.50percent"; case ..<88: return "battery.75percent"
                   default: return "battery.100percent" }
    }
    private func batteryColor(_ b: Int?) -> Color {
        guard let b else { return .secondary }
        return b < 20 ? .red : (b < 40 ? .yellow : .green)
    }
}

// MARK: - AI Radar

struct AIRadarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AIRadarWidget", provider: UnleashedProvider()) { entry in
            AIRadarView(entry: entry).widgetURL(URL(string: "unleashed://relay"))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Radar")
        .description("Provider usage from your AI Radar bridge.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AIRadarView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UnleashedEntry
    var body: some View {
        let providers = Array((entry.radar?.providers ?? []).prefix(family == .systemSmall ? 2 : 4))
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent").foregroundStyle(accent)
                Text("AI Radar").font(.headline)
            }
            if providers.isEmpty {
                Text("No usage data yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(providers) { p in providerRow(p) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func providerRow(_ p: SharedStore.RadarProvider) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(p.name).font(.caption).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text("\(p.shortUsed)%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(p.shortUsed >= 90 ? Color.red : accent)
                        .frame(width: max(3, geo.size.width * CGFloat(min(100, p.shortUsed)) / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Relay

struct RelayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RelayWidget", provider: UnleashedProvider()) { entry in
            RelayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sber relay")
        .description("Relay state with on/off controls.")
        .supportedFamilies([.systemSmall])
    }
}

struct RelayView: View {
    let entry: UnleashedEntry
    var body: some View {
        let on = entry.relay?.on
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "power").foregroundStyle(accent)
                Text("Relay").font(.headline)
                Spacer()
                // State only renders when the App Group delivers it (SideStore/AltStore);
                // under Feather there's no shared container, so we show controls only.
                if let on {
                    Text(on ? "ON" : "OFF").font(.caption).fontWeight(.bold)
                        .foregroundStyle(on ? .green : .secondary)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Link(destination: URL(string: "unleashed://relay/on")!) {
                    label("On", system: "power", tint: .green)
                }
                Link(destination: URL(string: "unleashed://relay/off")!) {
                    label("Off", system: "poweroff", tint: .secondary)
                }
            }
            Link(destination: URL(string: "unleashed://relay/toggle")!) {
                label("Toggle", system: "arrow.2.squarepath", tint: accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func label(_ t: String, system: String, tint: Color) -> some View {
        HStack(spacing: 4) { Image(systemName: system); Text(t).fontWeight(.semibold) }
            .font(.caption).frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(tint == .secondary ? Color.primary : tint)
    }
}

// MARK: - Quick actions

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickActionsWidget", provider: UnleashedProvider()) { _ in
            QuickActionsView().containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick actions")
        .description("Jump straight to Files, Screen, Relay or WiFi.")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickActionsView: View {
    private let actions: [(String, String, String)] = [
        ("Files", "folder.fill", "unleashed://files"),
        ("Screen", "rectangle.on.rectangle", "unleashed://screen"),
        ("Relay", "antenna.radiowaves.left.and.right", "unleashed://relay"),
        ("WiFi", "wifi", "unleashed://wifi"),
    ]
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill").foregroundStyle(accent)
                Text("TumoCompanion").font(.headline)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(actions, id: \.0) { a in
                    Link(destination: URL(string: a.2)!) {
                        VStack(spacing: 5) {
                            Image(systemName: a.1).font(.title3).foregroundStyle(accent)
                            Text(a.0).font(.caption2).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Live Activity (plugin / firmware install)

struct InstallLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InstallActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(progressText(context)).font(.caption).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction(context)).tint(.orange)
                        Text(context.state.done ? "Done" : context.state.name)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.orange)
            } compactTrailing: {
                Text(progressText(context)).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.orange)
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<InstallActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.orange)
                Text(context.attributes.title).font(.headline)
                Spacer()
                Text(progressText(context)).font(.subheadline).monospacedDigit()
            }
            ProgressView(value: fraction(context)).tint(.orange)
            Text(context.state.done ? "Done" : context.state.name)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding()
    }

    private func fraction(_ c: ActivityViewContext<InstallActivityAttributes>) -> Double {
        guard c.state.total > 0 else { return 0 }
        return min(1, Double(c.state.current) / Double(c.state.total))
    }
    private func progressText(_ c: ActivityViewContext<InstallActivityAttributes>) -> String {
        "\(Int(fraction(c) * 100))%"
    }
}
