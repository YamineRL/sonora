import Foundation
import MediaPlayer

/// One captured media-key event (headset touch panel or keyboard F-keys).
///
/// Serialized by the `/events` endpoint; `type` is one of
/// `"play-pause"`, `"next"`, `"previous"`, `"stop"`.
public struct MediaKeyEvent: Codable, Sendable, Equatable {
    public let seq: Int
    public let type: String
    /// ISO 8601 UTC timestamp of the capture.
    public let at: String

    public init(seq: Int, type: String, at: String) {
        self.seq = seq
        self.type = type
        self.at = at
    }
}

/// When the bridge claims the "now playing" role — i.e. when MediaRemote
/// routes the headset's taps and the keyboard's media keys to Sonora.
///
/// Resolved from `$SONORA_MEDIA_KEYS`; unknown values fall back to `.auto`.
public enum MediaKeyPolicy: String, Sendable {
    /// Claim only while a Sonora consumer is actively long-polling
    /// `/events` (seen within the last 30 s). The default.
    case auto
    /// Never claim: the browser (or whatever else) keeps the keys.
    case passive
    /// Always claim: Sonora owns the media keys while the bridge runs.
    case own
}

/// The read side of the media-key buffer, as the HTTP server needs it.
///
/// A protocol so `BridgeServer` (and its tests) never need MediaRemote.
public protocol MediaKeyEventSource: AnyObject {
    /// True while the bridge owns the media keys, i.e. it is the current
    /// now-playing app (mirrors the `mediaKeys` JSON field).
    var mediaKeysActive: Bool { get }
    /// Buffered events with `seq > since`, plus the current max sequence.
    func events(since: Int) -> (events: [MediaKeyEvent], seq: Int)
    /// Same as `events(since:)` but blocks up to `timeout` seconds until at
    /// least one event newer than `since` exists (long poll).
    func events(since: Int, waitingUpTo timeout: TimeInterval) -> (events: [MediaKeyEvent], seq: Int)
    /// Records that a Sonora consumer asked for events just now (drives the
    /// `.auto` claim policy).
    func noteConsumerSeen()
}

/// The side effect of owning the media keys: asserting (or dropping) the
/// system-wide "now playing" role.
///
/// A protocol so the policy state machine can be tested without touching
/// MediaPlayer — which needs a real app bundle and a main run loop.
public protocol NowPlayingClaiming: AnyObject {
    /// Assert (or re-assert) the now-playing role.
    func claim()
    /// Drop the now-playing role, handing the keys back to whoever claims
    /// next (usually the browser).
    func release()
}

/// Receives macOS media-key commands through **MediaRemote**.
///
/// Why not an event tap: the WH-1000XM4's touch-panel commands never enter
/// the input event stream at all. `bluetoothd` hands the AVRCP command to
/// MediaRemote (`rcd`), which delivers it straight to the current
/// *now-playing* app — a `CGEventTap`, at any tap location, never sees it.
/// (Verified live: a session tap saw nothing while an
/// `MPRemoteCommandCenter` target received every tap immediately.) Keyboard
/// media keys take the same MediaRemote route.
///
/// So the bridge does what a media player does: it registers
/// `MPRemoteCommandCenter` handlers and — when policy says so — makes itself
/// the now-playing app by publishing `MPNowPlayingInfoCenter` info with a
/// playing state. The most recent app to assert now-playing wins, which is
/// why the claim is re-asserted on a short timer: a browser tab starting
/// playback re-claims the role.
///
/// Received commands are recorded in a rolling buffer that the extension
/// polls at `GET /events?since=N&wait=S`. Sonora then decides what a tap
/// means: play/pause the controlled source, or switch to the next/previous
/// audible tab — while you're AFK.
///
/// The keys are **not** taken from other apps by default: see
/// `MediaKeyPolicy`. No Accessibility permission is involved.
public final class MediaKeyMonitor: ObservableObject, MediaKeyEventSource {

    /// True while the bridge holds the now-playing claim (main-thread mirror
    /// of `mediaKeysActive`, for the menu-bar UI).
    @Published public private(set) var isActive = false

    /// When the bridge claims the keys.
    public let policy: MediaKeyPolicy

    /// How long a `/events` request keeps the `.auto` policy claiming.
    public static let consumerWindow: TimeInterval = 30
    /// How often the claim is re-asserted while claiming. Short, because any
    /// app that starts playing (a browser tab, Music) takes the role away.
    public static let reassertInterval: TimeInterval = 2

    private let claimer: NowPlayingClaiming
    private var reassertTimer: Timer?
    /// Guards `events`, `sequence`, `claiming` and `lastConsumerSeen`, and
    /// wakes long-polling `/events` requests when an event is recorded.
    private let condition = NSCondition()
    private var events: [MediaKeyEvent] = []
    private var sequence = 0
    private var claiming = false
    private var lastConsumerSeen: Date?
    /// Rolling window kept in memory (the extension only ever asks for the
    /// tail, `seq > since`); 256 covers any realistic burst.
    private static let maxEvents = 256

    private static let iso = ISO8601DateFormatter()

    /// Creates a monitor.
    ///
    /// - Parameters:
    ///   - policy: when to claim the keys; `nil` resolves `$SONORA_MEDIA_KEYS`.
    ///   - claimer: the now-playing claim seam; `nil` uses the real
    ///     `MPNowPlayingInfoCenter`.
    public init(policy: MediaKeyPolicy? = nil, claimer: NowPlayingClaiming? = nil) {
        self.policy = policy ?? MediaKeyMonitor.policyFromEnvironment()
        self.claimer = claimer ?? NowPlayingInfoClaimer()
    }

    /// Resolves the claim policy from `$SONORA_MEDIA_KEYS`
    /// (`passive` / `own`); anything else — including unset — is `.auto`.
    public static func policyFromEnvironment() -> MediaKeyPolicy {
        guard let raw = ProcessInfo.processInfo.environment["SONORA_MEDIA_KEYS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return .auto
        }
        return MediaKeyPolicy(rawValue: raw) ?? .auto
    }

    /// Maps an `MPRemoteCommandCenter` command to a Sonora event type (pure,
    /// testable). Play and pause both fold into `play-pause`: the headset
    /// sends whichever one it thinks matches its idea of our state, and to
    /// Sonora a touch-panel tap is one toggle either way.
    public static func eventType(forCommand command: RemoteCommand) -> String {
        switch command {
        case .togglePlayPause, .play, .pause: return "play-pause"
        case .next: return "next"
        case .previous: return "previous"
        case .stop: return "stop"
        }
    }

    /// The MediaRemote commands the bridge handles.
    public enum RemoteCommand: String, Sendable, CaseIterable {
        case togglePlayPause, play, pause, next, previous, stop
    }

    // MARK: - Lifecycle

    /// Starts monitoring: registers the MediaRemote handlers and begins the
    /// claim/re-assert loop. Call once, from the main thread.
    public func start() {
        registerCommands()
        BridgeLog.log("[media-keys] MediaRemote handlers registered — policy=\(policy.rawValue)")
        refreshClaim()
        reassertTimer = Timer.scheduledTimer(
            withTimeInterval: Self.reassertInterval, repeats: true
        ) { [weak self] _ in
            self?.refreshClaim()
        }
    }

    public func stop() {
        reassertTimer?.invalidate()
        reassertTimer = nil
        if claiming {
            claimer.release()
            BridgeLog.log("[media-keys] released the now-playing claim (stopping)")
        }
        setClaiming(false)
    }

    // MARK: - Event source

    public var mediaKeysActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return claiming
    }

    /// All buffered events with `seq > since` plus the current max sequence.
    public func events(since: Int) -> (events: [MediaKeyEvent], seq: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (events.filter { $0.seq > since }, sequence)
    }

    /// Long-poll variant: waits up to `timeout` seconds for an event newer
    /// than `since`, then returns whatever is available (possibly nothing).
    public func events(
        since: Int,
        waitingUpTo timeout: TimeInterval
    ) -> (events: [MediaKeyEvent], seq: Int) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while sequence <= since, Date() < deadline {
            condition.wait(until: deadline)
        }
        return (events.filter { $0.seq > since }, sequence)
    }

    /// Records that a Sonora consumer asked for events just now.
    public func noteConsumerSeen() {
        condition.lock()
        lastConsumerSeen = Date()
        condition.unlock()
    }

    /// Appends an event and wakes any long-polling `/events` request.
    ///
    /// Called from the MediaRemote command handlers; also the seam the tests
    /// record through.
    public func record(type: String) {
        condition.lock()
        sequence += 1
        let event = MediaKeyEvent(seq: sequence, type: type, at: Self.iso.string(from: Date()))
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        condition.broadcast()
        condition.unlock()
    }

    // MARK: - Claim policy

    /// Whether the bridge should be the now-playing app right now.
    ///
    /// `.auto` claims only while a `/events` request has been seen within
    /// `consumerWindow` — so the browser keeps its keys unless Sonora is
    /// actually listening.
    public func shouldClaim(now: Date = Date()) -> Bool {
        switch policy {
        case .passive:
            return false
        case .own:
            return true
        case .auto:
            condition.lock()
            let seen = lastConsumerSeen
            condition.unlock()
            guard let seen else { return false }
            return now.timeIntervalSince(seen) <= Self.consumerWindow
        }
    }

    /// Brings the now-playing claim in line with the policy. Idempotent, and
    /// cheap enough to run on the re-assert timer: while claiming it re-sets
    /// the same info, which is what wins the role back from a browser tab
    /// that just started playing.
    ///
    /// Also the seam the policy tests drive, with an injected `now`.
    public func refreshClaim(now: Date = Date()) {
        let wanted = shouldClaim(now: now)
        let held = mediaKeysActive
        if wanted {
            claimer.claim()
            if !held {
                setClaiming(true)
                BridgeLog.log("[media-keys] claimed now-playing — Sonora owns the media keys "
                    + "(policy=\(policy.rawValue))")
            }
        } else if held {
            claimer.release()
            setClaiming(false)
            BridgeLog.log("[media-keys] released now-playing — keys go back to the system "
                + "(policy=\(policy.rawValue))")
        }
    }

    // MARK: - MediaRemote

    /// Registers a handler for every command Sonora understands and disables
    /// the rest, so macOS never offers seek/skip/rating controls for us.
    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let handled: [(MPRemoteCommand, RemoteCommand)] = [
            (center.togglePlayPauseCommand, .togglePlayPause),
            (center.playCommand, .play),
            (center.pauseCommand, .pause),
            (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous),
            (center.stopCommand, .stop),
        ]
        for (command, kind) in handled {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                self?.handle(command: kind)
                return .success
            }
        }
        let unhandled: [MPRemoteCommand] = [
            center.seekForwardCommand,
            center.seekBackwardCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.changePlaybackRateCommand,
            center.changeRepeatModeCommand,
            center.changeShuffleModeCommand,
            center.ratingCommand,
            center.likeCommand,
            center.dislikeCommand,
            center.bookmarkCommand,
        ]
        for command in unhandled {
            command.isEnabled = false
        }
    }

    private func handle(command: RemoteCommand) {
        let type = Self.eventType(forCommand: command)
        record(type: type)
        BridgeLog.log("[media-keys] received \(command.rawValue) from MediaRemote "
            + "→ \(type) (policy=\(policy.rawValue))")
    }

    /// Both flags move together; called from the main thread, so the
    /// `@Published` mirror can be assigned directly.
    private func setClaiming(_ value: Bool) {
        condition.lock()
        claiming = value
        condition.unlock()
        isActive = value
    }

    deinit {
        reassertTimer?.invalidate()
    }
}

/// The real claim: publish now-playing info with a playing state, which
/// makes this process the app MediaRemote routes media commands to.
final class NowPlayingInfoClaimer: NowPlayingClaiming {

    private let claimedAt = Date()

    func claim() {
        let center = MPNowPlayingInfoCenter.default()
        // MediaRemote routes commands to the app that most recently *changed*
        // its now-playing state; re-publishing identical info is a no-op and
        // the browser (which updates its position continuously) keeps the
        // keys. A fresh elapsed time makes every re-assert a real update.
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Sonora",
            MPMediaItemPropertyPlaybackDuration: 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Date().timeIntervalSince(claimedAt),
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        center.playbackState = .paused
        center.playbackState = .playing
    }

    func release() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }
}
