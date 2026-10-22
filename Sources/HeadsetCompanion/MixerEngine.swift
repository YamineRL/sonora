import AudioToolbox
import CoreAudio
import Foundation

/// The realtime half of the per-app mixer: process taps, a private
/// aggregate device that captures them, and a playback IOProc that mixes the
/// gain-adjusted audio back into the user's real output device.
///
/// Architecture (the same tap-and-render scheme other process-tap mixers
/// use — there is no per-process volume property in the HAL, only a mute):
///
///   app A ──tap (mutedWhenTapped)──┐
///   app B ──tap (mutedWhenTapped)──┼─► capture aggregate IOProc
///                                  │    (gain per app, mix to stereo)
///                                  ▼
///                            FloatRingBuffer
///                                  │
///   default output device ◄─playback IOProc (adds into outputData)
///
/// A tapped app stops reaching the speakers on its own
/// (`CATapMutedWhenTapped`), so what the user hears of it is exactly what the
/// mix writes — at `gain`. Untapped apps are never routed through us: the
/// playback proc *adds* its buffer into the device's output, which already
/// carries everyone else's mix. When no app is being adjusted the whole
/// pipeline is torn down and costs nothing.
///
/// Two clock notes that make the drift-free case work: the aggregate takes
/// the real output device as its main sub-device, so capture and playback
/// run on the same clock; and both IOProcs therefore deliver the same number
/// of frames per cycle, so the ring's fill level stays put instead of
/// walking.

/// Wait-free single-producer single-consumer float ring buffer — the handoff
/// between the capture IOProc (writer) and the playback IOProc (reader).
/// Capacity is a power of two so `index & mask` replaces the modulo on the
/// realtime path. Aligned UInt64 loads/stores are atomic on arm64/x86_64, so
/// head and tail need no lock.
final class FloatRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let mask: UInt64
    private let headPtr: UnsafeMutablePointer<UInt64>
    private let tailPtr: UnsafeMutablePointer<UInt64>

    init(requestedCapacity: Int) {
        var cap = 1
        while cap < max(2, requestedCapacity) { cap <<= 1 }
        capacity = cap
        mask = UInt64(cap - 1)
        buffer = .allocate(capacity: cap)
        buffer.initialize(repeating: 0)
        headPtr = .allocate(capacity: 1)
        tailPtr = .allocate(capacity: 1)
        headPtr.initialize(to: 0)
        tailPtr.initialize(to: 0)
    }

    deinit {
        buffer.deallocate()
        headPtr.deallocate()
        tailPtr.deallocate()
    }

    /// Samples currently buffered.
    var fillLevel: Int { Int(headPtr.pointee &- tailPtr.pointee) }

    /// Reset to empty. Not realtime-safe — call between rebuilds only.
    func reset() {
        headPtr.pointee = 0
        tailPtr.pointee = 0
    }

    /// Writes up to `count` samples; drops what doesn't fit (overrun reads as
    /// a momentary dropout rather than corruption). Returns the count taken.
    @discardableResult
    func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let head = headPtr.pointee
        let free = capacity - Int(head &- tailPtr.pointee)
        let n = min(count, free)
        if n <= 0 { return 0 }
        let writeStart = Int(head & mask)
        let first = min(n, capacity - writeStart)
        memcpy(buffer.baseAddress!.advanced(by: writeStart), src,
               first * MemoryLayout<Float>.size)
        if n > first {
            memcpy(buffer.baseAddress!, src.advanced(by: first),
                   (n - first) * MemoryLayout<Float>.size)
        }
        headPtr.pointee = head &+ UInt64(n)
        return n
    }

    /// Reads up to `count` samples into `dst`; returns the count actually
    /// delivered. Underrun returns fewer — the caller zeroes its scratch
    /// first so the shortfall is silence.
    @discardableResult
    func read(_ dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let head = headPtr.pointee
        let tail = tailPtr.pointee
        let n = min(count, Int(head &- tail))
        if n <= 0 { return 0 }
        let readStart = Int(tail & mask)
        let first = min(n, capacity - readStart)
        memcpy(dst, buffer.baseAddress!.advanced(by: readStart),
               first * MemoryLayout<Float>.size)
        if n > first {
            memcpy(dst.advanced(by: first), buffer.baseAddress!,
                   (n - first) * MemoryLayout<Float>.size)
        }
        tailPtr.pointee = tail &+ UInt64(n)
        return n
    }
}

/// The per-app gain the playback path reads. The Float lives behind a raw
/// pointer so the IOProc can read it on the realtime thread while the main
/// thread writes — a single aligned 32-bit store is atomic, and a stale read
/// is one buffer (~10 ms) of the previous gain.
final class GainSlot {
    private(set) var gain: Float = 1.0
    private let pointer: UnsafeMutablePointer<Float>

    init(pointer: UnsafeMutablePointer<Float>) {
        self.pointer = pointer
        pointer.pointee = 1.0
    }

    func setGain(_ value: Float) {
        let clamped = min(max(value, 0), MixerApp.maxGain)
        gain = clamped
        pointer.pointee = clamped
    }
}

/// An `AudioHardwareCreateProcessTap` handle. `CATapMutedWhenTapped` keeps
/// the process out of the bound device+stream's mix so the only copy of its
/// audio reaching that device is the one the capture device hands us.
@available(macOS 14.2, *)
final class MixerProcessTap {
    let tapID: AudioObjectID

    /// `processObjectIDs` are HAL process objects (from the `prs#` list), not
    /// pids — one tap can mix down every process a bundle owns.
    ///
    /// The tap is bound to the playback device's first output stream: a
    /// device-bound muted tap removes the process from *that* device while
    /// leaving its process stream alive for capture — the device-agnostic
    /// `stereoMixdownOfProcesses` variant instead tears the whole stream
    /// down on some processes (Chromium helpers deliver no buffers at all).
    /// The trade-off: a process routed to a *different* device isn't muted
    /// there and won't arrive through this tap — the dead-tap watchdog
    /// treats that as unsupported rather than silence it.
    init(processObjectIDs: [AudioObjectID], outputDeviceUID: String, label: String) throws {
        let description = CATapDescription(processes: processObjectIDs, deviceUID: outputDeviceUID, stream: 0)
        description.name = "HeadsetCompanion.\(label)"
        description.isPrivate = true
        // CATapMutedWhenTapped is raw value 2; Swift's name folding can't
        // produce the case from the `isMuted` getter.
        description.muteBehavior = CATapMuteBehavior(rawValue: 2) ?? .unmuted
        description.isExclusive = false
        description.isMixdown = true
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            throw MixerEngineError.tapFailed(status: status)
        }
        self.tapID = tapID
    }

    deinit {
        AudioHardwareDestroyProcessTap(tapID)
    }
}

/// The capture half: a private aggregate device holding the output device
/// (clock source — its data is discarded) plus every process tap. The IOProc
/// applies each tap's gain, mixes to one stereo stream, writes the ring.
@available(macOS 14.2, *)
final class MixerCaptureDevice {
    let aggregateID: AudioObjectID
    let gainSlots: [GainSlot]
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let ring: FloatRingBuffer
    private let gainBuffer: UnsafeMutableBufferPointer<Float>
    /// [0] samples mixed into the ring, [1] of those, samples that were
    /// actually non-zero — distinguishes "pipeline dead" from "pipeline
    /// flowing silence". Then per-tap: [2..<2+n] non-zero input counts,
    /// [2+n..<2+2n] total input counts — a tap whose *total* never rises
    /// isn't flowing silence, its reroute never delivered a stream at all
    /// (e.g. a process routed to a different output device); a tap whose
    /// total rises but non-zero doesn't is stale-bound or a genuinely
    /// quiet app.
    private let counterBuffer: UnsafeMutableBufferPointer<UInt64>
    var samplesCaptured: UInt64 { counterBuffer[0] }
    var nonzeroCaptured: UInt64 { counterBuffer[1] }
    /// Per-tap non-zero input counts, same order as `gainSlots` — the
    /// watchdog signal: a tap whose count stops rising is dead, not silent.
    var tapNonzero: [UInt64] {
        Array(counterBuffer[2..<(2 + gainSlots.count)])
    }
    /// Per-tap input totals, same order — see `counterBuffer` above for why
    /// zero delivered buffers is a different failure than zeroed buffers.
    var tapTotal: [UInt64] {
        Array(counterBuffer[(2 + gainSlots.count)..<(2 + 2 * gainSlots.count)])
    }
    /// One-shot flag so the first IOProc can dump the buffer layout.
    private var didLogPtr = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    init(outputDeviceUID: String, taps: [MixerProcessTap], ring: FloatRingBuffer) throws {
        self.ring = ring
        precondition(taps.count <= 32)
        let gains = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, taps.count))
        gains.initialize(repeating: 1.0)
        gainBuffer = gains
        gainSlots = (0..<taps.count).map { GainSlot(pointer: gains.baseAddress!.advanced(by: $0)) }
        let counters = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 2 + 2 * max(1, taps.count))
        counters.initialize(repeating: 0)
        counterBuffer = counters
        didLogPtr.initialize(to: 0)

        var tapList: [[String: Any]] = []
        for tap in taps {
            if let uid = Self.tapUID(tap.tapID) {
                tapList.append([kAudioSubTapUIDKey: uid])
            }
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "io.sonora.headsetcompanion.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "HeadsetCompanion Mixer",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // The real output as main sub-device: same clock as the playback
            // IOProc, so the ring doesn't drift.
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            gains.deallocate()
            counters.deallocate()
            throw MixerEngineError.aggregateFailed(status: status)
        }
        self.aggregateID = aggregateID
    }

    deinit {
        stop()
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        gainBuffer.deallocate()
        counterBuffer.deallocate()
        didLogPtr.deallocate()
    }

    func start() throws {
        let gains = gainBuffer.baseAddress!
        let slotCount = gainSlots.count
        let ring = self.ring
        let counters = counterBuffer.baseAddress!
        let didLog = didLogPtr
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, nil
        ) { _, input, _, output, _ in
            Self.capture(input: input, output: output, gains: gains,
                         slotCount: slotCount, ring: ring, counters: counters,
                         didLog: didLog)
        }
        guard status == noErr, let procID else {
            throw MixerEngineError.ioProcFailed(status: status)
        }
        ioProcID = procID
        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            throw MixerEngineError.startFailed(status: startStatus)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        isRunning = false
    }

    /// Largest expected IOProc buffer (2048 samples ≈ 21 ms stereo at 48 kHz).
    private static let scratchSamples = 2048

    /// Realtime path — no allocation, no locks, no main-actor anything.
    private static func capture(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gains: UnsafeMutablePointer<Float>,
        slotCount: Int,
        ring: FloatRingBuffer,
        counters: UnsafeMutablePointer<UInt64>,
        didLog: UnsafeMutablePointer<UInt32>
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // The aggregate's output goes nowhere — it exists to carry the taps.
        for b in outList {
            if let m = b.mData {
                m.assumingMemoryBound(to: Float.self)
                    .update(repeating: 0, count: Int(b.mDataByteSize) / 4)
            }
        }

        // One-shot layout dump — the only way to see how the HAL actually
        // shaped the tap buffers on this machine. Single write on the first
        // callback only; still not strictly RT-safe but one-time.
        if didLog.pointee == 0 {
            didLog.pointee = 1
            var msg = "[capture] in=\(inList.count)"
            for (i, b) in inList.enumerated() {
                msg += " [\(i)]ch=\(b.mNumberChannels),bytes=\(b.mDataByteSize)"
            }
            msg += " out=\(outList.count)"
            for (i, b) in outList.enumerated() {
                msg += " [\(i)]ch=\(b.mNumberChannels),bytes=\(b.mDataByteSize)"
            }
            msg += " slots=\(slotCount)\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        var mixSamples = 0
        let tapCount = min(inList.count, slotCount)
        for i in 0..<tapCount {
            mixSamples = max(mixSamples, Int(inList[i].mDataByteSize) / 4)
        }
        if mixSamples == 0 { return }
        mixSamples = min(mixSamples, scratchSamples)

        withUnsafeTemporaryAllocation(of: Float.self, capacity: mixSamples) { mix in
            mix.update(repeating: 0)
            var nonzero: UInt64 = 0
            for i in 0..<tapCount {
                guard let mData = inList[i].mData else { continue }
                let samples = mData.assumingMemoryBound(to: Float.self)
                let n = min(Int(inList[i].mDataByteSize) / 4, mixSamples)
                var tapNZ: UInt64 = 0
                let g = gains.advanced(by: i).pointee
                for f in 0..<n {
                    let s = samples[f]
                    if s != 0 { tapNZ &+= 1 }
                    mix[f] += s * g
                }
                counters[2 + i] &+= tapNZ
                counters[2 + slotCount + i] &+= UInt64(n)
                nonzero &+= tapNZ
            }
            // Boosted sums can overshoot — clip, don't wrap.
            for f in 0..<mixSamples {
                mix[f] = min(max(mix[f], -1), 1)
            }
            counters[0] &+= UInt64(ring.write(mix.baseAddress!, count: mixSamples))
            counters[1] &+= nonzero
        }
    }

    private static func tapUID(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(0x74756964), // 'tuid'
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }
}

/// The playback half: an IOProc on the user's real output device that adds
/// the ring's contents into `outputData` — *into*, not onto, so the system's
/// own mix of every untapped app stays intact.
final class MixerPlaybackDevice {
    let deviceID: AudioObjectID
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let ring: FloatRingBuffer
    /// [0] samples mixed into the device output, [1] underrun samples
    /// (ring was empty when the device asked — the tap pipeline fell behind),
    /// [2] samples read from the ring that were non-zero.
    private let counterBuffer: UnsafeMutableBufferPointer<UInt64>
    var samplesPlayed: UInt64 { counterBuffer[0] }
    var underrunSamples: UInt64 { counterBuffer[1] }
    var nonzeroPlayed: UInt64 { counterBuffer[2] }
    private var didLogPtr = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    init(deviceID: AudioObjectID, ring: FloatRingBuffer) {
        self.deviceID = deviceID
        self.ring = ring
        let counters = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: 3)
        counters.initialize(repeating: 0)
        counterBuffer = counters
        didLogPtr.initialize(to: 0)
    }

    deinit {
        stop()
        if let ioProcID { AudioDeviceDestroyIOProcID(deviceID, ioProcID) }
        counterBuffer.deallocate()
        didLogPtr.deallocate()
    }

    func start() throws {
        let ring = self.ring
        let counters = counterBuffer.baseAddress!
        let didLog = didLogPtr
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, deviceID, nil
        ) { _, _, _, output, _ in
            Self.playback(output: output, ring: ring, counters: counters, didLog: didLog)
        }
        guard status == noErr, let procID else {
            throw MixerEngineError.ioProcFailed(status: status)
        }
        ioProcID = procID
        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            throw MixerEngineError.startFailed(status: startStatus)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(deviceID, ioProcID)
        isRunning = false
    }

    private static let scratchSamples = 4096

    /// Realtime path — same constraints as the capture side.
    private static func playback(
        output: UnsafeMutablePointer<AudioBufferList>,
        ring: FloatRingBuffer,
        counters: UnsafeMutablePointer<UInt64>,
        didLog: UnsafeMutablePointer<UInt32>
    ) {
        let outList = UnsafeMutableAudioBufferListPointer(output)

        if didLog.pointee == 0 {
            didLog.pointee = 1
            var msg = "[playback] out=\(outList.count)"
            for (i, b) in outList.enumerated() {
                msg += " [\(i)]ch=\(b.mNumberChannels),bytes=\(b.mDataByteSize)"
            }
            msg += "\n"
            FileHandle.standardError.write(Data(msg.utf8))
        }

        guard let outB = outList.first, let m = outB.mData else { return }
        let out = m.assumingMemoryBound(to: Float.self)
        let n = min(Int(outB.mDataByteSize) / 4, scratchSamples)

        withUnsafeTemporaryAllocation(of: Float.self, capacity: n) { scratch in
            scratch.update(repeating: 0)
            let read = ring.read(scratch.baseAddress!, count: n)
            var nonzero: UInt64 = 0
            for f in 0..<read {
                let s = scratch[f]
                if s != 0 { nonzero &+= 1 }
                out[f] = min(max(out[f] + s, -1), 1)
            }
            counters[0] &+= UInt64(read)
            counters[1] &+= UInt64(n - read)
            counters[2] &+= nonzero
        }
    }
}

enum MixerEngineError: Swift.Error, CustomStringConvertible {
    case noDefaultDevice
    case tapFailed(status: OSStatus)
    case aggregateFailed(status: OSStatus)
    case ioProcFailed(status: OSStatus)
    case startFailed(status: OSStatus)

    var description: String {
        switch self {
        case .noDefaultDevice: return "no default output device"
        case .tapFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s)"
        case .aggregateFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)"
        case .ioProcFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed: \(s)"
        case .startFailed(let s): return "AudioDeviceStart failed: \(s)"
        }
    }
}

/// Owns one full pipeline (taps → capture aggregate → ring → playback) for a
/// fixed set of apps. Rebuilt from scratch whenever the tapped set or the
/// default output device changes — a slider move alone just writes a
/// `GainSlot`, which is the cheap path on purpose.
@available(macOS 14.2, *)
final class MixerEngine {

    /// One entry in `MixerEngine.start(apps:)`: which process objects to tap
    /// for this app row.
    struct TappedApp {
        let key: String
        let processObjectIDs: [AudioObjectID]
        /// Gain the slot starts with, before the first `setGain` from the
        /// main thread. A muted app must not play a buffer at unity while
        /// the engine spins up.
        var initialGain: Float = 1
    }

    private var taps: [MixerProcessTap] = []
    private var capture: MixerCaptureDevice?
    private var playback: MixerPlaybackDevice?
    private var ring: FloatRingBuffer?
    private var slots: [String: GainSlot] = [:]
    /// App key → tap index, same order the taps were passed to the capture
    /// device — indexes into its `tapNonzero` array.
    private var keyToTapIndex: [String: Int] = [:]
    private(set) var isRunning = false

    /// Builds the whole chain. Throws partway-complete-free: anything made
    /// before the failure is released via the locals' deinits.
    func start(apps: [TappedApp], outputDeviceID: AudioDeviceID, outputDeviceUID: String) throws {
        stop()

        var taps: [MixerProcessTap] = []
        var order: [String] = []
        for app in apps where !app.processObjectIDs.isEmpty {
            do {
                taps.append(try MixerProcessTap(processObjectIDs: app.processObjectIDs, outputDeviceUID: outputDeviceUID, label: app.key))
                order.append(app.key)
            } catch {
                // One untappable process (it may have exited mid-build) must
                // not take down the apps that did tap.
                BridgeLog.log("[mixer] tap failed for \(app.key): \(error)")
            }
        }
        guard !taps.isEmpty else {
            throw MixerEngineError.aggregateFailed(status: kAudioHardwareUnsupportedOperationError)
        }

        let ring = FloatRingBuffer(requestedCapacity: 8192)
        let capture = try MixerCaptureDevice(outputDeviceUID: outputDeviceUID, taps: taps, ring: ring)
        // Seed every slot before the IOProc starts, so a muted app's first
        // buffer is already at gain 0 rather than at the slot's unity init.
        let initialGains = Dictionary(uniqueKeysWithValues: apps.map { ($0.key, $0.initialGain) })
        for (i, key) in order.enumerated() {
            capture.gainSlots[i].setGain(initialGains[key] ?? 1)
        }
        try capture.start()
        let playback = MixerPlaybackDevice(deviceID: outputDeviceID, ring: ring)
        try playback.start()

        self.taps = taps
        self.capture = capture
        self.playback = playback
        self.ring = ring
        slots = Dictionary(uniqueKeysWithValues: zip(order, capture.gainSlots))
        keyToTapIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        isRunning = true
    }

    func setGain(_ gain: Float, forKey key: String) {
        slots[key]?.setGain(gain)
    }

    /// Apps the running capture has a gain slot for. Mute for these is gain
    /// 0, not `pimt`: a pimt-muted process can stop feeding the tap, which
    /// the zero-flow watchdog would read as a dead reroute.
    var tappedKeys: Set<String> { Set(slots.keys) }

    /// Frame counters for the log and tests: samples that entered the ring,
    /// samples that left it to the device, samples the device wanted but the
    /// ring didn't have, and on each side how many of those were non-zero —
    /// that pair is what separates "pipeline dead" from "flowing silence".
    var stats: (captured: UInt64, played: UInt64, underrun: UInt64, capturedNonzero: UInt64, playedNonzero: UInt64) {
        (capture?.samplesCaptured ?? 0, playback?.samplesPlayed ?? 0,
         playback?.underrunSamples ?? 0, capture?.nonzeroCaptured ?? 0,
         playback?.nonzeroPlayed ?? 0)
    }

    /// Per-app running counters of what each tap delivered: `total` is every
    /// sample the tap handed us, `nonzero` how many carried signal. A tap
    /// whose total stops rising has no stream at all — e.g. the process is
    /// routed to a different output device, so the device-bound mute can't
    /// capture it — which no rebuild fixes. A tap whose total rises but
    /// non-zero doesn't is stale-bound or a genuinely quiet app — recreate
    /// it to re-bind.
    var perAppFlow: [String: (total: UInt64, nonzero: UInt64)] {
        guard let capture else { return [:] }
        let nz = capture.tapNonzero
        let tt = capture.tapTotal
        var out: [String: (total: UInt64, nonzero: UInt64)] = [:]
        for (key, i) in keyToTapIndex where i < nz.count && i < tt.count {
            out[key] = (total: tt[i], nonzero: nz[i])
        }
        return out
    }

    func stop() {
        playback?.stop()
        playback = nil
        capture?.stop()
        capture = nil
        ring?.reset()
        ring = nil
        taps.removeAll()
        slots.removeAll()
        keyToTapIndex.removeAll()
        isRunning = false
    }

    deinit { stop() }
}
