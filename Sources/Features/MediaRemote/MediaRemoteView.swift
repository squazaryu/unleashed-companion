import SwiftUI
import Combine

/// App Bridge app id shared with the Flipper `media_remote` FAP.
private enum MediaBridge {
    static let appID = "media_remote"
    static let nowPlaying = "now_playing"   // phone -> FAP: current track
    static let fieldSep: Character = "\u{1f}"   // unit separator between artist/title/state
}

/// Reads the system now-playing via `MediaRemoteController` and relays it to the
/// Flipper `media_remote` FAP over App Bridge, while accepting transport commands
/// coming back from the FAP's buttons. Also usable purely as a diagnostic probe:
/// the screen shows exactly what MediaRemote returns, so it's obvious whether the
/// private-framework path works on this iOS version before any FAP exists.
@MainActor
final class MediaRemoteViewModel: ObservableObject {
    @Published private(set) var nowPlaying: MediaRemoteController.NowPlaying?
    @Published private(set) var relaying = false
    @Published private(set) var lastRelayAt: Date?
    @Published private(set) var lastCommand: String?

    let controller = MediaRemoteController()
    var isAvailable: Bool { controller.isAvailable }

    private let ble: FlipperBLE
    private var commandSub: AnyCancellable?
    private var pollTask: Task<Void, Never>?
    private var observing = false

    init(ble: FlipperBLE = .shared) {
        self.ble = ble
    }

    /// Arm MediaRemote change notifications and pull the first snapshot. Idempotent.
    func onAppear() {
        if !observing, controller.isAvailable {
            observing = true
            controller.startObserving()
            NotificationCenter.default.addObserver(
                self, selector: #selector(mediaChanged),
                name: MediaRemoteController.didChange, object: nil)
        }
        Task { await refresh() }
    }

    /// Stop the bridge and drop the change observer when the screen goes away, so
    /// no poll loop / App Bridge subscription outlives the view.
    func onDisappear() {
        stopRelay()
        if observing {
            NotificationCenter.default.removeObserver(self, name: MediaRemoteController.didChange, object: nil)
            observing = false
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)   // safety net; safe from any thread
    }

    @objc private func mediaChanged() {
        Task { await refresh(relayIfChanged: true) }
    }

    func refresh(relayIfChanged: Bool = false) async {
        let np = await controller.fetch()
        let changed = np != nowPlaying
        nowPlaying = np
        if relaying, relayIfChanged, changed { sendNowPlaying() }
    }

    // MARK: - Manual transport (drives the SYSTEM media session for testing)

    func command(_ c: MediaRemoteController.Command) {
        controller.send(c)
        Task {
            // Give the media app a beat to update, then reflect the new state.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refresh(relayIfChanged: true)
        }
    }

    // MARK: - Relay to Flipper

    func setRelaying(_ on: Bool) {
        on ? startRelay() : stopRelay()
    }

    private func startRelay() {
        guard !relaying else { return }
        relaying = true
        // Listen for the FAP's button presses (command carries the action).
        commandSub = ble.appBridgeIn
            .filter { $0.appID == MediaBridge.appID }
            .sink { [weak self] frame in self?.handleIncoming(frame) }
        sendNowPlaying()   // push the current track immediately
        // Some media apps don't post reliable change notifications; poll as a
        // low-rate fallback so the Flipper still tracks progress/track changes.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.refresh(relayIfChanged: true)
            }
        }
    }

    private func stopRelay() {
        relaying = false
        commandSub?.cancel(); commandSub = nil
        pollTask?.cancel(); pollTask = nil
    }

    private func handleIncoming(_ frame: AppBridgeFrame) {
        let action: MediaRemoteController.Command?
        switch frame.command {
        case "next":              action = .nextTrack
        case "prev":              action = .previousTrack
        case "playpause", "toggle": action = .togglePlayPause
        case "play":              action = .play
        case "pause":             action = .pause
        default:                  action = nil
        }
        guard let action else { return }
        lastCommand = frame.command
        controller.send(action)
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            await refresh(relayIfChanged: true)
        }
    }

    private func sendNowPlaying() {
        let np = nowPlaying ?? .init(artist: "", title: "", album: "", isPlaying: false)
        // Keep each field short so the whole frame stays under the App Bridge v2
        // 160-byte cap; the FAP scrolls anything that doesn't fit on screen anyway.
        func clip(_ s: String) -> String { String(s.prefix(60)) }
        let payload = "\(clip(np.artist))\(MediaBridge.fieldSep)\(clip(np.title))"
            + "\(MediaBridge.fieldSep)\(np.isPlaying ? "1" : "0")"
        ble.sendAppBridge(appID: MediaBridge.appID, command: MediaBridge.nowPlaying,
                          payload: Data(payload.utf8))
        lastRelayAt = Date()
    }
}

struct MediaRemoteView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm = MediaRemoteViewModel()

    var body: some View {
        CardScroll {
            availabilityCard
            if vm.isAvailable {
                nowPlayingCard
                controlsCard
                relayCard
            }
        }
        .navigationTitle("Media Remote")
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.onAppear() }
        .onDisappear { vm.onDisappear() }
    }

    private var availabilityCard: some View {
        SectionCard(title: "MediaRemote", systemImage: "music.note.list",
                    accessory: AnyView(StatusPill(
                        text: vm.isAvailable ? "Available" : "Unavailable",
                        color: vm.isAvailable ? .green : .orange,
                        systemImage: vm.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill"))) {
            if !vm.isAvailable {
                Label("iOS doesn't expose the system now-playing to this app on your version — the MediaRemote private framework is restricted here. The Flipper relay can't read tracks on this device.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reads whatever app currently holds the system media session (Spotify, Apple Music, Podcasts, …).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nowPlayingCard: some View {
        SectionCard(title: "Now Playing", systemImage: "waveform") {
            if let np = vm.nowPlaying, !np.isEmpty {
                infoRow("Title", np.title.isEmpty ? "—" : np.title)
                infoRow("Artist", np.artist.isEmpty ? "—" : np.artist)
                if !np.album.isEmpty { infoRow("Album", np.album) }
                HStack {
                    Text("State").foregroundStyle(.secondary)
                    Spacer()
                    StatusPill(text: np.isPlaying ? "Playing" : "Paused",
                               color: np.isPlaying ? .green : .secondary,
                               systemImage: np.isPlaying ? "play.fill" : "pause.fill")
                }
            } else {
                Text("Nothing playing — start a track in Spotify or Apple Music, or MediaRemote returned no data on your iOS.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PillButton(title: "Refresh", systemImage: "arrow.clockwise", tint: .secondary) {
                Task { await vm.refresh() }
            }
        }
    }

    private var controlsCard: some View {
        SectionCard(title: "Transport", systemImage: "playpause.circle") {
            Text("Test controlling the current media session directly from the phone.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                controlButton("backward.fill") { vm.command(.previousTrack) }
                controlButton("playpause.fill") { vm.command(.togglePlayPause) }
                controlButton("forward.fill") { vm.command(.nextTrack) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var relayCard: some View {
        SectionCard(title: "Relay to Flipper", systemImage: "antenna.radiowaves.left.and.right",
                    accessory: AnyView(StatusPill(
                        text: ble.supportsAppBridge ? "App Bridge" : "No bridge",
                        color: ble.supportsAppBridge ? .green : .orange,
                        systemImage: "dot.radiowaves.left.and.right"))) {
            Toggle(isOn: Binding(get: { vm.relaying }, set: { vm.setRelaying($0) })) {
                Text("Stream now-playing to the media_remote FAP")
                    .font(.subheadline)
            }
            .disabled(!ble.supportsAppBridge)
            if let at = vm.lastRelayAt {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Sent").font(.caption).foregroundStyle(.secondary)
                    Text(at, style: .relative).font(.caption).foregroundStyle(.secondary)
                    Text("ago").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let cmd = vm.lastCommand {
                Text("Last command from Flipper: \(cmd)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("Open the media_remote app on the Flipper — its buttons will control playback here, and the current track shows on its screen.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func controlButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 64, height: 44)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
