import Foundation

/// Thin wrapper over the private `MediaRemote.framework` so the app can read the
/// SYSTEM "now playing" (whatever app is currently the media session — Spotify,
/// Apple Music, Podcasts, …) and send transport commands to it.
///
/// This is a private Apple framework: fine for a sideloaded build (Feather), but
/// Apple has progressively restricted it — on some iOS versions
/// `MRMediaRemoteGetNowPlayingInfo` returns nothing to unentitled third-party
/// apps. That's exactly why the Media Remote screen surfaces the raw result: it's
/// the ground-truth probe for whether this path is usable on a given device.
///
/// Everything is loaded via `dlopen`/`dlsym` so a future iOS that removes a symbol
/// degrades to "unavailable" instead of failing to launch.
final class MediaRemoteController {
    struct NowPlaying: Equatable {
        var artist: String
        var title: String
        var album: String
        var isPlaying: Bool

        var isEmpty: Bool { artist.isEmpty && title.isEmpty && album.isEmpty }
    }

    /// Subset of `MRMediaRemoteCommand` we drive from the Flipper buttons.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    /// Posted (on the main queue) whenever the system now-playing changes, after
    /// `startObserving()` has armed MediaRemote's notifications.
    static let didChange = Notification.Name("com.tumoflip.mediaremote.didChange")

    private typealias GetNowPlayingInfoFn =
        @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias SendCommandFn = @convention(c) (Int, NSDictionary?) -> Bool

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: GetNowPlayingInfoFn?
    private let register: RegisterFn?
    private let sendCommandFn: SendCommandFn?

    private let artistKey: String
    private let titleKey: String
    private let albumKey: String
    private let playbackRateKey: String

    /// True when every symbol we need resolved. A false here means "this iOS build
    /// doesn't expose MediaRemote to us" — not a transient error.
    let isAvailable: Bool

    private var changeToken: NSObjectProtocol?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        handle = h

        func fn<T>(_ name: String, as type: T.Type) -> T? {
            guard let h, let sym = dlsym(h, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        // A private-framework `NSString * const`: dlsym gives the address of the
        // storage holding the string pointer, so read it back as an NSString.
        func str(_ name: String) -> String? {
            guard let h, let sym = dlsym(h, name) else { return nil }
            return unsafeBitCast(sym, to: UnsafePointer<NSString>.self).pointee as String
        }

        getNowPlayingInfo = fn("MRMediaRemoteGetNowPlayingInfo", as: GetNowPlayingInfoFn.self)
        register = fn("MRMediaRemoteRegisterForNowPlayingNotifications", as: RegisterFn.self)
        sendCommandFn = fn("MRMediaRemoteSendCommand", as: SendCommandFn.self)

        // Fall back to the well-known literal key names if the exported constants
        // can't be resolved (their string VALUES have been stable for years).
        artistKey = str("kMRMediaRemoteNowPlayingInfoArtist") ?? "kMRMediaRemoteNowPlayingInfoArtist"
        titleKey = str("kMRMediaRemoteNowPlayingInfoTitle") ?? "kMRMediaRemoteNowPlayingInfoTitle"
        albumKey = str("kMRMediaRemoteNowPlayingInfoAlbum") ?? "kMRMediaRemoteNowPlayingInfoAlbum"
        playbackRateKey = str("kMRMediaRemoteNowPlayingInfoPlaybackRate")
            ?? "kMRMediaRemoteNowPlayingInfoPlaybackRate"

        isAvailable = getNowPlayingInfo != nil && sendCommandFn != nil
    }

    /// Arm MediaRemote's change notifications and forward them as `didChange`.
    /// Safe to call more than once — only one underlying observer is kept.
    func startObserving() {
        guard changeToken == nil else { return }
        register?(.main)
        // MediaRemote posts this Darwin/NSNotification when the now-playing info or
        // playback state changes; re-broadcast under our own stable name.
        changeToken = NotificationCenter.default.addObserver(
            forName: Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil, queue: .main) { _ in
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
    }

    deinit {
        if let changeToken { NotificationCenter.default.removeObserver(changeToken) }
    }

    /// One-shot read of the current system now-playing. Returns nil when MediaRemote
    /// is unavailable or hands back nothing (both are real, informative outcomes).
    func fetch() async -> NowPlaying? {
        guard let getNowPlayingInfo else { return nil }
        return await withCheckedContinuation { cont in
            getNowPlayingInfo(.main) { [artistKey, titleKey, albumKey, playbackRateKey] info in
                guard let info else { cont.resume(returning: nil); return }
                let artist = (info[artistKey] as? String) ?? ""
                let title = (info[titleKey] as? String) ?? ""
                let album = (info[albumKey] as? String) ?? ""
                let rate = (info[playbackRateKey] as? NSNumber)?.doubleValue ?? 0
                let np = NowPlaying(artist: artist, title: title, album: album, isPlaying: rate > 0)
                cont.resume(returning: np)
            }
        }
    }

    /// Send a transport command to the current media session. Returns false when
    /// MediaRemote is unavailable or refused the command.
    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let sendCommandFn else { return false }
        return sendCommandFn(command.rawValue, nil)
    }
}
