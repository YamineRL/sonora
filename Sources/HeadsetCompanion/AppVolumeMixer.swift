import AppKit
import CoreAudio
import Foundation

/// One row in the mixer's app list: a real app (or helper process) that is
/// currently running audio output, with the user's level for it.
public struct MixerApp: Identifiable {
    /// Slider ceiling — the 150 % the menu advertises.
    public static let maxGain: Float = 1.5

    /// Bundle ID, or `"pid:<n>"` for processes that don't carry one
    /// (command-line players, scripts). Keyed this way so the user's level
    /// survives the process object being destroyed and recreated.
    public let key: String
    public let name: String
    public let icon: NSImage?
    public var volume: Float
    public var muted: Bool
    /// The HAL process objects this row covers — several when an app's audio
    /// lives in helper processes; one tap can mix them all down.
    public let processObjectIDs: [AudioObjectID]
    /// False when this process set proved untappable: `CATapMutedWhenTapped`
    /// tore its stream down but delivered no replacement, so any level below
    /// 100 % would just silence it. The slider disables; mute (`pimt`,
    /// which needs no tap) stays available.
    public var supportsVolumeControl: Bool = true

    public var id: String { key }

    /// Silence is gain 0 on the tap path (or `pimt` for untappable
    /// processes); the UI dims on the same predicate.
    public var effectivelyMuted: Bool { muted || volume <= 0 }
    /// What the tap's gain slot should carry: zero for anything muted (or
    /// pulled to 0), otherwise the user's level.
    public var gain: Float { effectivelyMuted ? 0 : volume }
    /// Whether the tap/gain path is needed. Mute goes through it too, as
    /// gain 0 — `pimt` proved unreliable on real processes (and a `pimt`'d
    /// process can stop feeding the tap, which the watchdog reads as dead).
    /// `pimt` remains the fallback for processes that cannot be tapped.
    public var adjusted: Bool { muted || abs(volume - 1) > 0.02 }
    /// Already at the native path: unity (within the same band) and unmuted.
    /// The row's reset control is a no-op in this state.
    public var isDefault: Bool { !muted && abs(volume - 1) <= 0.02 }
}

/// The mixer's model and orchestrator: which processes are producing audio,
/// what level the user wants each at, and the `MixerEngine` rebuilds that
/// keep the taps matching the adjusted set.
///
/// Two mechanisms, chosen per app:
///  - **volume and mute** (process tap + gain): the only mechanism CoreAudio
///    offers between 0 % and 150 %. A tap pulls the app's audio out of the
///    device mix and hands it to `MixerEngine`, which gains and re-renders
///    it; mute is gain 0 on that same path.
///  - **mute fallback** (`pimt` on the process object): a documented but
///    headerless HAL property, used only for processes the taps cannot
///    cover (no grant, pre-14.2, or a proven-untappable stream).
///
/// Detection is push + poll: the `prs#` listener catches processes joining
/// and leaving, per-object `piro` listeners catch a process starting to
/// play, and a 1 s poll closes the gap for transitions the HAL doesn't
/// always notify on.
@MainActor
public final class AppVolumeMixer: ObservableObject {

    /// Rows for the menu, sorted by name. Only processes running audio
    /// output make the list — the mixer is a list of apps making sounds.
    @Published public private(set) var apps: [MixerApp] = []

    /// TCC state for System Audio Recording. Until this is authorized the
    /// tap path stays inert: creating a `mutedWhenTapped` tap without the
    /// grant is exactly what turns "turn that app down" into "that app went
    /// silent", because the tap mutes the process but delivers zero samples.
    @Published public private(set) var systemAudioAccess: SystemAudioPermission.Status = .undetermined

    /// Whether the gain pipeline may run. `.unavailable` means the TCC SPI is
    /// missing but the OS can still host process taps, so try them. Pre-14.2
    /// has no process-object API at all: the app rows may exist, but their
    /// sliders must stay disabled rather than silently no-op.
    public var canControlVolume: Bool {
        guard #available(macOS 14.2, *) else { return false }
        return systemAudioAccess == .authorized || systemAudioAccess == .unavailable
    }

    // MARK: - Internal state

    /// The user's level per app key, kept when an app's process objects are
    /// destroyed and recreated (pause/resume can flip the object).
    private struct Setting { var volume: Float; var muted: Bool }
    private var settings: [String: Setting] = [:]

    /// The gain pipeline; `nil` whenever no app is adjusted or on pre-14.2.
    private var engine: AnyObject?
    /// What the currently running engine was built for — app keys + their
    /// process objects + the output device. Rebuilt only when this changes.
    private var engineSignature = ""
    /// Back-off for a failed `engine.start`: the signature that failed and
    /// until when not to retry it, so a persistent failure doesn't rebuild
    /// (and log) once per poll.
    private var engineFailed = (signature: "", retryAt: Date.distantPast)

    /// Process objects we have `pimt`'d to 1, so they can be unmuted on
    /// transitions, object turnover, and app quit. Writing 0 only where we
    /// wrote 1 also means the mixer never touches an app's mute it didn't set.
    private var mutedObjects = Set<AudioObjectID>()
    /// Object IDs that already have a `piro` listener.
    private var observedObjects = Set<AudioObjectID>()

    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pollTimer: Timer?

    // MARK: - Selectors

    /// `kAudioHardwarePropertyProcessObjectList` ('prs#').
    private nonisolated static let processObjectList = AudioObjectPropertySelector(0x70727323)
    /// `kAudioProcessPropertyPID` ('ppid').
    private nonisolated static let processPID = AudioObjectPropertySelector(0x70706964)
    /// `kAudioProcessPropertyBundleID` ('pbid').
    private nonisolated static let processBundleID = AudioObjectPropertySelector(0x70626964)
    /// `kAudioProcessPropertyIsRunningOutput` ('piro').
    private nonisolated static let processIsRunningOutput = AudioObjectPropertySelector(0x7069726F)
    /// `kAudioProcessPropertyIsMuted` ('pimt') — documented in AudioHardware.h
    /// but left out of the SDK's enum; verified present and settable on every
    /// output-running process object.
    private nonisolated static let processIsMuted = AudioObjectPropertySelector(0x70696D74)
    /// `kAudioDevicePropertyDeviceUID` ('uid ').
    private nonisolated static let deviceUID = AudioObjectPropertySelector(0x75696420)

    // MARK: - Init

    public init() {
        // Push: process objects appearing and leaving.
        addSystemListener(Self.processObjectList) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        // And a slow poll: `piro` transitions on a live object don't change
        // the list itself, and the HAL occasionally misses one entirely.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Unmute everything we muted before exiting — a `pimt` write outlives
        // this process (it lives on the target's process object), so quitting
        // without this would leave apps silent forever.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Synchronous on purpose: the app exits right after this
            // notification, so a Task hop could lose the unmute writes.
            MainActor.assumeIsolated { self?.restoreAllMuted() }
        }
        // The grant can be toggled in System Settings while the app runs;
        // losing it has to tear the taps down instead of leaving the app
        // muted with a silent replacement stream.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSystemAudioAccess() }
        }
        updateSystemAudioAccess()
        refresh()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Public API

    /// Moves an app's level. Dragging off zero clears a mute — the same rule
    /// the menu's own volume slider follows.
    public func setVolume(_ newValue: Float, for key: String) {
        let clamped = min(max(newValue, 0), MixerApp.maxGain)
        var setting = settings[key] ?? Setting(volume: 1, muted: false)
        setting.volume = clamped
        if clamped > 0 { setting.muted = false }
        settings[key] = setting
        if let i = apps.firstIndex(where: { $0.key == key }) {
            apps[i].volume = clamped
            apps[i].muted = setting.muted
        }
        // First slider touch with no decision yet: ask now, then apply the
        // level once the grant lands. Until then the app keeps playing
        // natively instead of being tapped and silenced.
        if systemAudioAccess == .undetermined { requestSystemAudioAccess() }
        reconcile()
    }

    public func toggleMuted(for key: String) {
        var setting = settings[key] ?? Setting(volume: 1, muted: false)
        setting.muted.toggle()
        settings[key] = setting
        if let i = apps.firstIndex(where: { $0.key == key }) {
            apps[i].muted = setting.muted
        }
        reconcile()
    }

    /// Back to the native path: 100 %, unmuted, tap released. The row's
    /// reset control is this in one click, instead of trying to land a
    /// 280 pt slider exactly on the unity tick.
    public func resetToDefault(for key: String) {
        setVolume(1, for: key)
    }

    /// Engine frame counters (nil while no pipeline is running) — the proof
    /// in `/debug` logs and tests that tapped audio is actually flowing.
    var engineStats: (captured: UInt64, played: UInt64, underrun: UInt64, capturedNonzero: UInt64, playedNonzero: UInt64)? {
        guard #available(macOS 14.2, *),
              let engine = engine as? MixerEngine, engine.isRunning else { return nil }
        return engine.stats
    }

    /// Rate-limit on the stats line so the poll doesn't spam the log.
    private var lastStatsLog = Date.distantPast

    // MARK: - System Audio Recording permission

    /// Re-read TCC. Turning the grant off in System Settings must stop the
    /// taps immediately; otherwise they keep muting apps and feeding zeros.
    private func updateSystemAudioAccess() {
        let status = SystemAudioPermission.current()
        guard status != systemAudioAccess else { return }
        systemAudioAccess = status
        if !canControlVolume {
            if #available(macOS 14.2, *) {
                (engine as? MixerEngine)?.stop()
            }
            engineSignature = ""
            flow = [:]
        }
        reconcile()
    }

    /// Shows the system consent prompt when the user has not decided yet.
    /// Called by the menu's Allow button and by the first slider touch.
    public func requestSystemAudioAccess() {
        guard canControlVolume == false else { return }
        if systemAudioAccess == .denied {
            // A previous denial can only be changed in System Settings.
            updateSystemAudioAccess()
            return
        }
        SystemAudioPermission.requestAccess { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.systemAudioAccess = granted ? .authorized : .denied
                self.reconcile()
            }
        }
    }

    /// Per-key tap-flow state for the watchdog. Two failure shapes matter:
    /// a tap that keeps delivering *zeroed* buffers is stale-bound (rebuild
    /// re-binds it), while a tap that delivers *no* buffers at all is a
    /// reroute the HAL can't make — it tore the process's stream down with
    /// `CATapMutedWhenTapped` and never handed the copy to us.
    struct TapFlow {
        var objects: [AudioObjectID] = []
        var lastTotal: UInt64 = 0
        var lastNonzero: UInt64 = 0
        var lastFlowAt = Date()
        var deadSince: Date?
        var deadWindows = 0
        /// The tap handed us real signal at least once on this object set —
        /// proof the reroute *can* work, so later silence is a stale bind or
        /// a pause, never grounds for giving up on the process.
        var everNonzero = false
    }
    private var flow: [String: TapFlow] = [:]
    /// Keys whose current process objects can't be rerouted: excluded from
    /// the tap set so the app keeps playing natively. Reset implicitly when
    /// the object's set changes — a fresh set might tap cleanly.
    private var unsupported: [String: [AudioObjectID]] = [:]
    private var lastStaleRebuildAt: [String: Date] = [:]
    private static let staleAfter: TimeInterval = 10
    private static let staleRebuildEvery: TimeInterval = 30
    /// No-buffer taps get two `deadAfter`-second windows — one rebuild
    /// between them — before the process set is written off.
    private static let deadAfter: TimeInterval = 6
    private static let maxDeadWindows = 2

    /// The device the running engine was started on, and the earliest time
    /// a post-switch start is allowed. Taps created while the HAL is still
    /// rerouting a just-changed default output can bind to a dead stream —
    /// the exact stale-tap case the watchdog repairs — so a device change
    /// delays the next start briefly. During the wait the affected apps
    /// simply keep playing through the normal path.
    private var engineDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var engineReadyAt = Date.distantPast

    // MARK: - Reconciliation

    /// Applies the current model to the world: an engine rebuild if the
    /// tapped set or the output device moved, then the mutes for processes
    /// the taps cannot carry, then the gains.
    private func reconcile() {
        // Rebuild first: `applyMutes` needs to know which apps the running
        // engine carries, so it can use `pimt` only for the rest.
        rebuildEngineIfNeeded()
        applyMutes()
        pushGains()
    }

    /// `pimt` is the fallback for processes no tap covers: a muted app the
    /// engine carries is silenced by gain 0 instead. Live values are read
    /// every pass (pimt outlives this process), but writes only happen on a
    /// real transition, so the poll isn't a write storm.
    private func applyMutes() {
        // Apps carried by the gain pipeline are muted by gain 0; `pimt` is
        // only for processes the taps cannot cover. Clear pimt on tapped
        // apps so a stale write (or an app that just became tappable) can't
        // leave them silent behind our back.
        let gainedKeys: Set<String>
        if #available(macOS 14.2, *),
           let engine = engine as? MixerEngine, engine.isRunning {
            gainedKeys = engine.tappedKeys
        } else {
            gainedKeys = []
        }
        var live = Set<AudioObjectID>()
        for app in apps {
            let handledByGain = gainedKeys.contains(app.key)
            let shouldMute = app.effectivelyMuted && !handledByGain
            for object in app.processObjectIDs {
                live.insert(object)
                var address = Self.address(Self.processIsMuted)
                // Read the live value instead of trusting `mutedObjects`:
                // a pimt write outlives this process, so a previous launch
                // (or a killed app) can leave a process muted even though
                // our bookkeeping is empty.
                var current: UInt32 = 0
                var currentSize = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(
                    object, &address, 0, nil, &currentSize, &current
                ) == noErr else { continue }
                let isMuted = current != 0
                // Mute where the tap can't carry it; clear a pimt on a
                // tapped app (it can starve the tap) or one we wrote
                // ourselves. A pimt another mixer set on an untappable app
                // is left alone.
                if shouldMute {
                    if isMuted {
                        // Already muted: own it so a later unmute clears it,
                        // even if the write came from a previous launch.
                        mutedObjects.insert(object)
                        continue
                    }
                } else if !isMuted || !(handledByGain || mutedObjects.contains(object)) {
                    continue
                }
                var value: UInt32 = shouldMute ? 1 : 0
                if AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(4), &value) == noErr {
                    if shouldMute { mutedObjects.insert(object) } else { mutedObjects.remove(object) }
                    BridgeLog.log("[mixer] \(shouldMute ? "muted" : "cleared mute on") \(app.key) via pimt (tap \(handledByGain ? "handles" : "cannot handle") it)")
                }
            }
        }
        // Objects that vanished can't be muted — drop the bookkeeping.
        mutedObjects.formIntersection(live)
    }

    /// The engine mirrors the set of adjusted apps exactly: signature first,
    /// rebuild only when it moved — a slider tick that stays inside the tap
    /// band writes a GainSlot and never reaches here.
    private func rebuildEngineIfNeeded() {
        guard #available(macOS 14.2, *) else { return }
        // No grant, no taps: a silent tap is worse than no tap, because it
        // removes the app from the device mix while contributing nothing.
        guard canControlVolume else {
            (engine as? MixerEngine)?.stop()
            engineSignature = ""
            return
        }
        let tapped = apps.filter { $0.adjusted && $0.supportsVolumeControl }
        var signature = "\(AudioOutputController.readDefaultOutputDevice())|"
        signature += tapped
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.processObjectIDs.sorted().description)" }
            .joined(separator: ",")
        guard signature != engineSignature else { return }
        // A retry of the same signature waits out the back-off; a different
        // signature (apps moved, device switched) rebuilds right away.
        guard !(signature == engineFailed.signature && Date() < engineFailed.retryAt) else { return }

        let engine = (engine as? MixerEngine) ?? MixerEngine()
        self.engine = engine
        engine.stop()
        engineSignature = signature
        guard !tapped.isEmpty else { return }
        let outputID = AudioOutputController.readDefaultOutputDevice()
        if outputID != kAudioObjectUnknown, engineDeviceID != kAudioObjectUnknown,
           outputID != engineDeviceID {
            engineReadyAt = Date().addingTimeInterval(1.5)
        }
        engineDeviceID = outputID
        guard Date() >= engineReadyAt else {
            // Not marked ready: signature stays unset and the next poll
            // comes back here once the route has had a moment to settle.
            engineSignature = ""
            return
        }
        guard outputID != kAudioObjectUnknown,
              let outputUID = Self.readString(outputID, Self.deviceUID) else {
            BridgeLog.log("[mixer] no default output device — pipeline off")
            return
        }
        do {
            try engine.start(
                apps: tapped.map {
                    MixerEngine.TappedApp(
                        key: $0.key,
                        processObjectIDs: $0.processObjectIDs,
                        initialGain: $0.gain)
                },
                outputDeviceID: outputID,
                outputDeviceUID: outputUID
            )
            engineFailed = ("", .distantPast)
        } catch {
            BridgeLog.log("[mixer] engine start failed: \(error)")
            // The rows stay visible; sliders just stop applying. `signature`
            // keeps matching nothing-running, so the poll retries — but only
            // after the back-off.
            engineSignature = ""
            engineFailed = (signature, Date().addingTimeInterval(10))
        }
    }

    /// Every reconcile pushes the current gains into the running slots —
    /// the path a slider tick takes when the tapped set didn't change. A
    /// write into a slot that doesn't exist (app not tapped) is a no-op.
    private func pushGains() {
        guard #available(macOS 14.2, *),
              let engine = engine as? MixerEngine else { return }
        for app in apps where app.adjusted && app.supportsVolumeControl {
            engine.setGain(app.gain, forKey: app.key)
        }
    }

    // MARK: - Detection

    /// Rebuilds `apps` from the live process list and pushes it through
    /// reconcile. Called by the system listener, the per-object listeners
    /// and the poll — all on the main queue.
    private func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let objects = Self.readObjectList(system, Self.processObjectList)
        observeOutputFlags(of: objects)

        var byKey: [String: (objects: [AudioObjectID], pid: pid_t)] = [:]
        for object in objects {
            guard Self.readUInt32(object, Self.processIsRunningOutput) == 1 else { continue }
            guard let pid = Self.readPID(object) else { continue }
            let rawBundle = Self.readString(object, Self.processBundleID)
            let key: String
            if let rawBundle, !rawBundle.isEmpty {
                let parent = Self.parentBundleID(of: rawBundle)
                guard !Self.hiddenBundles.contains(where: { parent.hasPrefix($0) }) else { continue }
                key = parent
            } else {
                key = "pid:\(pid)"
            }
            var entry = byKey[key] ?? (objects: [], pid: pid)
            entry.objects.append(object)
            byKey[key] = entry
        }

        var rows: [MixerApp] = byKey.map { key, entry in
            let setting = settings[key] ?? Setting(volume: 1, muted: false)
            let (name, icon) = Self.identity(for: key, pid: entry.pid)
            let objects = entry.objects.sorted()
            return MixerApp(
                key: key, name: name, icon: icon,
                volume: setting.volume, muted: setting.muted,
                processObjectIDs: objects,
                supportsVolumeControl: unsupported[key] != objects
            )
        }
        rows.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        apps = rows
        reconcile()
        watchTaps()
        if let stats = engineStats, Date() > lastStatsLog.addingTimeInterval(5) {
            lastStatsLog = Date()
            BridgeLog.log("[mixer] stats captured=\(stats.captured) nonzero=\(stats.capturedNonzero) played=\(stats.played) nonzero=\(stats.playedNonzero) underrun=\(stats.underrun)")
        }
    }

    /// What one tap's counters told us this poll — see `watchTaps`.
    enum TapAction: Equatable {
        /// Signal arrived — everything reset.
        case flowing
        /// Buffers arriving but all zero: within the stale grace window.
        case quiet
        /// Zeroed buffers past `staleAfter`: stale bind — rebuild.
        case stale
        /// No buffers at all past `deadAfter`: the reroute delivered no
        /// stream. Rebuild once; a second consecutive window on a tap that
        /// never produced signal becomes `.unsupported`.
        case deadWindow
        /// The process set can't be rerouted — exclude it from the taps.
        case unsupported
    }

    /// Per-tap liveness check, run off the same 1 Hz poll. See the `TapFlow`
    /// block above for why zeroed buffers and absent buffers are different
    /// failures with different remedies.
    private func watchTaps() {
        guard #available(macOS 14.2, *),
              let engine = engine as? MixerEngine, engine.isRunning else {
            flow = [:]
            return
        }
        let now = Date()
        let perApp = engine.perAppFlow
        let objectsByKey = Dictionary(uniqueKeysWithValues: apps.map { ($0.key, $0.processObjectIDs) })
        var needsRebuild = false
        for (key, counters) in perApp {
            var state = flow[key] ?? TapFlow()
            if state.objects != objectsByKey[key] {
                // Fresh process objects — fresh chances: a new set might
                // reroute where the old one couldn't.
                state = TapFlow(objects: objectsByKey[key] ?? [])
            }
            // A rebuild restarts the counters at zero — re-base the state
            // instead of reading the drop as "no stream".
            if counters.total < state.lastTotal || counters.nonzero < state.lastNonzero {
                state.lastTotal = counters.total
                state.lastNonzero = counters.nonzero
                state.deadSince = nil
            }
            let action = Self.classifyTap(
                total: counters.total, nonzero: counters.nonzero,
                state: &state, now: now,
                staleAfter: Self.staleAfter, deadAfter: Self.deadAfter,
                maxDeadWindows: Self.maxDeadWindows
            )
            flow[key] = state
            switch action {
            case .stale:
                guard now.timeIntervalSince(lastStaleRebuildAt[key] ?? .distantPast) > Self.staleRebuildEvery else { break }
                lastStaleRebuildAt[key] = now
                BridgeLog.log("[mixer] tap for \(key) has delivered only zeros for \(Int(Self.staleAfter))s — rebuilding (stale bind)")
                needsRebuild = true
            case .deadWindow:
                BridgeLog.log("[mixer] tap for \(key) delivered no stream for \(Int(Self.deadAfter))s — rebuilding")
                needsRebuild = true
            case .unsupported:
                unsupported[key] = state.objects
                // Flip the live row too — the rebuild this triggers happens
                // before the next refresh rebuilds the rows.
                if let i = apps.firstIndex(where: { $0.key == key }) {
                    apps[i].supportsVolumeControl = false
                }
                BridgeLog.log("[mixer] \(key) cannot be rerouted — its tap delivered no stream after \(Self.maxDeadWindows) attempts; excluding it so it plays natively")
                needsRebuild = true
            case .flowing, .quiet:
                break
            }
        }
        flow = flow.filter { perApp.keys.contains($0.key) }
        lastStaleRebuildAt = lastStaleRebuildAt.filter { perApp.keys.contains($0.key) }
        if needsRebuild {
            engineSignature = ""
            reconcile()
        }
    }

    /// The pure half of `watchTaps`: fold this poll's counters into the
    /// key's flow state and say what the poll should do about it.
    nonisolated static func classifyTap(
        total: UInt64, nonzero: UInt64,
        state: inout TapFlow, now: Date,
        staleAfter: TimeInterval, deadAfter: TimeInterval,
        maxDeadWindows: Int
    ) -> TapAction {
        if nonzero > state.lastNonzero {
            state.lastNonzero = nonzero
            state.lastTotal = total
            state.lastFlowAt = now
            state.deadSince = nil
            state.deadWindows = 0
            state.everNonzero = true
            return .flowing
        }
        if total > state.lastTotal {
            // Buffers still arrive — the stream lives, it's just all zeros.
            state.lastTotal = total
            state.deadSince = nil
            return now.timeIntervalSince(state.lastFlowAt) > staleAfter ? .stale : .quiet
        }
        // No buffers at all. A tap that once produced signal has a working
        // reroute and just paused — same remedy as stale. One that never
        // did gets `maxDeadWindows` chances, then gives up: muting took but
        // the reroute never will.
        guard let deadSince = state.deadSince,
              now.timeIntervalSince(deadSince) >= deadAfter else {
            if state.deadSince == nil { state.deadSince = now }
            return .quiet
        }
        state.deadSince = nil
        guard !state.everNonzero else { return .stale }
        state.deadWindows += 1
        return state.deadWindows >= maxDeadWindows ? .unsupported : .deadWindow
    }

    /// `piro` on a live object doesn't change `prs#` — so every known object
    /// gets its own listener, or a paused→playing transition could wait a
    /// full poll interval.
    private func observeOutputFlags(of objects: [AudioObjectID]) {
        let current = Set(objects)
        for object in current.subtracting(observedObjects) {
            addListener(object: object,
                        address: Self.address(Self.processIsRunningOutput)) { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
        }
        for object in observedObjects.subtracting(current) {
            removeListeners(for: object)
        }
        observedObjects.formIntersection(current)
    }

    // MARK: - Listener plumbing (same shape as AudioOutputController's)

    private func addSystemListener(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping () -> Void
    ) {
        addListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            address: Self.address(selector),
            handler: handler
        )
    }

    private func addListener(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping () -> Void
    ) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return }
        listenerBlocks.append((object, address, block))
    }

    private func removeListeners(for object: AudioObjectID) {
        listenerBlocks.removeAll { entry in
            guard entry.0 == object else { return false }
            var address = entry.1
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, entry.2)
            return true
        }
    }

    // MARK: - Process object reads

    nonisolated static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func readObjectList(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    nonisolated static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let string = (value as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private nonisolated static func readPID(_ object: AudioObjectID) -> pid_t? {
        guard let raw = readUInt32(object, processPID) else { return nil }
        return pid_t(raw)
    }

    // MARK: - Identity

    /// Display name + icon for a row: the running app behind the bundle,
    /// then the bundle on disk, then the pid as a last resort.
    nonisolated static func identity(for key: String, pid: pid_t) -> (name: String, icon: NSImage?) {
        if !key.hasPrefix("pid:") {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: key)
            if let app = running.first(where: { $0.activationPolicy == .regular }) ?? running.first,
               let name = app.localizedName {
                return (name, sized(app.icon))
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
                let name = url.deletingPathExtension().lastPathComponent
                return (name, sized(NSWorkspace.shared.icon(forFile: url.path)))
            }
            let short = key.split(separator: ".").last.map(String.init) ?? key
            return (short, nil)
        }
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return (name, sized(app.icon))
        }
        return ("PID \(pid)", nil)
    }

    private nonisolated static func sized(_ icon: NSImage?) -> NSImage? {
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }

    /// Collapses helper processes onto their parent app the way the Dock
    /// does: `com.google.Chrome.helper` is Chrome, `x.helper.Renderer` is x.
    /// The longest markers come first so `.helper.Renderer` strips fully.
    nonisolated static func parentBundleID(of bundleID: String) -> String {
        let markers = [
            ".helper", ".Helper", ".renderer", ".Renderer",
            ".gpu", ".GPU", ".GeckoMediaPlugin", ".plugin-container",
            ".AudioService", ".webcontent", ".WebContent",
        ]
        for marker in markers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }
        return bundleID
    }

    /// System audio sources the user can't meaningfully mix, and ourselves.
    nonisolated static let hiddenBundles = [
        "io.sonora.headsetcompanion",
        "com.apple.audiomxd",
        "com.apple.coreaudiod",
        "com.apple.mediaremoted",
        "com.apple.assistantd",
        "com.apple.SiriNCService",
        "com.apple.CoreSpeech",
        "com.apple.universalaccessd",
        "com.apple.controlcenter",
        "com.apple.PowerChime",
        "com.apple.loginwindow",
        "com.apple.AirPlayXPCHelper",
        "com.apple.TelephonyUtilities",
        "com.apple.avconferenced",
        "systemsoundserverd",
    ]

    /// Called on `willTerminate`: every object still carrying our `pimt` gets
    /// it back to 0 — the mute lives on the target's process object, so it
    /// would otherwise outlive this process.
    private func restoreAllMuted() {
        var address = Self.address(Self.processIsMuted)
        var value: UInt32 = 0
        for object in mutedObjects {
            AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(4), &value)
        }
        mutedObjects.removeAll()
    }
}
