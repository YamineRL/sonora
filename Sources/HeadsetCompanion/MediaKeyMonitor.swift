import Foundation
import MediaPlayer

/// One captured media-key event (headset touch panel or keyboard F-keys).
///
/// Serialized by the `/events` endpoint; `type` is one of
/// `"play-pause"`, `"next"`, `"previous"`, `"stop"`,
/// `"seek-forward"`, `"seek-backward"`.
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
    ///
    /// `force` picks how hard we fight for it. A forced claim toggles the
    /// playback state (`paused` → `playing`), which is what wins the role
    /// back from a browser tab that just started playing — but every toggle
    /// is a *system-wide* MediaRemote broadcast that wakes ControlCenter,
    /// `audiomxd`, `audioaccessoryd` and `bluetoothd`, and re-arbitrates the
    /// shared audio route. An unforced claim is a single state update, cheap
    /// enough to run as an idle heartbeat.
    func claim(force: Bool)
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
    /// How often the claim is re-asserted right after you actually use the
    /// keys. Short, because any app that starts playing (a browser tab,
    /// Music) takes the role away.
    public static let reassertInterval: TimeInterval = 2
    /// How long the fast cadence lasts after a real media-key press.
    public static let fastWindow: TimeInterval = 10
    /// Re-assert cadence once idle. A compromise, and the knob to turn if
    /// either symptom comes back: at 2 s the claim generated ~5,700
    /// unified-log events a minute and re-arbitrated the shared audio route
    /// 30 times a minute; too slow and the headset buttons go dead for that
    /// long every time a browser tab starts playing and takes the role.
    public static let idleReassertInterval: TimeInterval = 15

    private let claimer: NowPlayingClaiming
    private var reassertTimer: Timer?
    /// Guards `events`, `sequence`, `claiming` and `lastConsumerSeen`, and
    /// wakes long-polling `/events` requests when an event is recorded.
    private let condition = NSCondition()
    private var events: [MediaKeyEvent] = []
    private var sequence = 0
    private var claiming = false
    private var lastConsumerSeen: Date?
    /// When a media key was last actually pressed — opens the fast window.
    private var lastInteractionAt: Date?
    /// When the claim was last asserted, forced or not.
    private var lastClaimAt: Date?
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
    /// testable).
    ///
    /// Only `togglePlayPause` is a toggle. `play` and `pause` are passed
    /// through literally, because they do not come from the headset at all —
    /// they come from macOS.
    ///
    /// This used to fold all three into `play-pause`, on the assumption that
    /// the touch panel sent whichever one matched its idea of our state. It
    /// does not: across 70 logged commands the panel sent `togglePlayPause`
    /// 13 times, `play` zero times, and every one of the 16 `pause` commands
    /// came from the system. The worst of them arrives when the Bluetooth
    /// audio route is torn down — macOS pauses the now-playing app so sound
    /// does not jump to the speakers, we turned that into a toggle, and a
    /// video the user had deliberately paused started playing out loud:
    ///
    ///     [09:19:59] [media-keys] received pause ... -> play-pause
    ///     [09:19:59] [bridge] system readings: []      <- headset powered off
    ///
    /// A literal `pause` is idempotent, so the same command is now correct
    /// whether or not anything was playing.
    public static func eventType(forCommand command: RemoteCommand) -> String {
        switch command {
        case .togglePlayPause: return "play-pause"
        case .play: return "play"
        case .pause: return "pause"
        case .next: return "next"
        case .previous: return "previous"
        case .stop: return "stop"
        case .seekForward: return "seek-forward"
        case .seekBackward: return "seek-backward"
        }
    }

    /// Whether a command represents someone actually pressing something, as
    /// opposed to macOS steering the now-playing app. Only the former opens
    /// the fast re-assert window.
    public static func isUserInteraction(_ command: RemoteCommand) -> Bool {
        switch command {
        case .play, .pause: return false
        case .togglePlayPause, .next, .previous, .stop: return true
        case .seekForward, .seekBackward: return true
        }
    }

    /// The MediaRemote commands the bridge handles.
    public enum RemoteCommand: String, Sendable, CaseIterable {
        case togglePlayPause, play, pause, next, previous, stop
        /// AVRCP fast-forward / rewind: the headset's *held* next/previous
        /// gesture (swipe-and-hold on the XM4 touch panel). Delivered as
        /// `MPSeekCommandEvent`s, begin and end; only the begin is recorded.
        case seekForward, seekBackward
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
    /// `interaction` is false for commands macOS sends us on its own (see
    /// `eventType(forCommand:)`): those must not open the forced re-claim
    /// window. A system `pause` arrives exactly as the Bluetooth route is
    /// being torn down, and 10 s of forced now-playing toggles is the one
    /// thing guaranteed to make that teardown stall.
    public func record(type: String, at now: Date = Date(), interaction: Bool = true) {
        condition.lock()
        if interaction { lastInteractionAt = now }
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
            if !held {
                // First claim: fight for the role and start the fast window.
                claimer.claim(force: true)
                noteClaimed(at: now)
                setClaiming(true)
                BridgeLog.log("[media-keys] claimed now-playing — Sonora owns the media keys "
                    + "(policy=\(policy.rawValue))")
            } else if reassertDue(now: now) != nil {
                // Always forced. An unforced re-publish does not take the role
                // back from a browser that is actively playing — only the
                // paused→playing toggle does. Making the idle heartbeat
                // unforced deadlocked the keys: Brave took the role, so Sonora
                // received no commands, so the fast (forced) window never
                // opened, so it never took the role back. Zero next/previous
                // reached the bridge in the 8 h that shipped. Cost is bounded
                // by the cadence instead: 4 claims/min idle, against the 30 a
                // 2 s forced cadence was doing when it stalled the machine.
                claimer.claim(force: true)
                noteClaimed(at: now)
            }
        } else if held {
            claimer.release()
            setClaiming(false)
            BridgeLog.log("[media-keys] released now-playing — keys go back to the system "
                + "(policy=\(policy.rawValue))")
        }
    }

    /// Whether the claim is due for a re-assert, and how hard.
    ///
    /// Returns `nil` when nothing is due, `true` when the fast (forced)
    /// cadence applies — within `fastWindow` of a real key press — and
    /// `false` for the idle heartbeat.
    func reassertDue(now: Date = Date()) -> Bool? {
        condition.lock()
        let interaction = lastInteractionAt
        let claimed = lastClaimAt
        condition.unlock()

        let fast = interaction.map { now.timeIntervalSince($0) <= Self.fastWindow } ?? false
        let interval = fast ? Self.reassertInterval : Self.idleReassertInterval
        guard let claimed else { return fast }
        guard now.timeIntervalSince(claimed) >= interval else { return nil }
        return fast
    }

    private func noteClaimed(at now: Date) {
        condition.lock()
        lastClaimAt = now
        condition.unlock()
    }

    // MARK: - MediaRemote

    /// Registers a handler for every command Sonora understands and disables
    /// the rest, so macOS never offers skip/rating controls for us.
    ///
    /// The seek pair is registered separately: it arrives as
    /// `MPSeekCommandEvent`s in `.beginSeeking` / `.endSeeking` pairs, and a
    /// held gesture must produce exactly one Sonora event, so only the begin
    /// is recorded.
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
        let seeks: [(MPRemoteCommand, RemoteCommand)] = [
            (center.seekForwardCommand, .seekForward),
            (center.seekBackwardCommand, .seekBackward),
        ]
        for (command, kind) in seeks {
            command.isEnabled = true
            command.addTarget { [weak self] event in
                guard let seek = event as? MPSeekCommandEvent,
                      seek.type == .beginSeeking else { return .success }
                self?.handle(command: kind)
                return .success
            }
        }
        let unhandled: [MPRemoteCommand] = [
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
        record(type: type, interaction: Self.isUserInteraction(command))
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

    func claim(force: Bool) {
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
        // The paused→playing toggle is the part that reliably steals the role
        // back, and also the part that costs two system-wide broadcasts. Pay
        // it only in the fast window; the idle heartbeat settles for the
        // single `playing` update above, which still reclaims when the role
        // has drifted elsewhere.
        if force {
            center.playbackState = .paused
        }
        center.playbackState = .playing
    }

    func release() {
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }
}
