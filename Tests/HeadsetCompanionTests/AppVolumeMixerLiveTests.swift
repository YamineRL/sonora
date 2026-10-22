import CoreAudio
import Foundation
import XCTest

@testable import HeadsetCompanion

/// Live check of the whole mixer path against a real playing process: the
/// `afplay` binary has no bundle ID, so it also exercises the `pid:` row
/// fallback. Skipped without a default output device (headless CI).
@MainActor
final class AppVolumeMixerLiveTests: XCTestCase {

    /// 12 s of 440 Hz sine as 16-bit PCM WAV — long enough that piro stays 1
    /// through the partial-volume, mute, and mute-from-unity phases.
    private func writeTone(to url: URL) throws {
        let rate = 44_100
        let frames = rate * 12
        var pcm = [UInt8]()
        pcm.reserveCapacity(frames * 2)
        for i in 0..<frames {
            let s = Int16(sin(2 * .pi * 440 * Double(i) / Double(rate)) * 16_000)
            pcm.append(UInt8(s & 0xff)); pcm.append(UInt8(s >> 8 & 0xff))
        }
        var header = [UInt8]()
        func four(_ s: String) { header.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { (0..<4).forEach { header.append(UInt8(v >> (8 * $0) & 0xff)) } }
        func u16(_ v: UInt16) { (0..<2).forEach { header.append(UInt8(v >> (8 * $0) & 0xff)) } }
        four("RIFF"); u32(UInt32(36 + pcm.count)); four("WAVE")
        four("fmt "); u32(16); u16(1); u16(1); u32(UInt32(rate))
        u32(UInt32(rate * 2)); u16(2); u16(16)
        four("data"); u32(UInt32(pcm.count))
        try Data(header + pcm).write(to: url)
    }

    func testMixerControlsAPlayingProcess() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "live audio tap test is local-only")
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("process objects need macOS 14.2")
        }
        guard AudioOutputController.readDefaultOutputDevice() != kAudioObjectUnknown else {
            throw XCTSkip("no default output device")
        }

        let tone = URL(fileURLWithPath: "/tmp/headsetcompanion-mixer-tone.wav")
        try writeTone(to: tone)

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        try player.run()
        defer { player.terminate() }

        let mixer = AppVolumeMixer()
        let key = "pid:\(player.processIdentifier)"
        defer {
            // Never leave the test player muted or tapped if an assert fails.
            mixer.resetToDefault(for: key)
        }

        var app: MixerApp?
        for _ in 0..<40 where app == nil {
            app = mixer.apps.first { $0.key == key }
            if app == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        let row = try XCTUnwrap(app, "afplay never showed up as a mixer row")

        // Partial volume → the tap pipeline must carry real samples.
        mixer.setVolume(0.5, for: key)
        try await Task.sleep(for: .seconds(1.5))
        let stats = try XCTUnwrap(mixer.engineStats, "engine did not start")
        XCTAssertGreaterThan(stats.captured, 0, "taps delivered no audio")
        XCTAssertGreaterThan(stats.played, 0, "playback IOProc wrote nothing")
        XCTAssertGreaterThan(stats.capturedNonzero, 0, "taps flowed but carried only silence")
        XCTAssertGreaterThan(stats.playedNonzero, 0, "nonzero audio never reached the device output buffer")

        // Mute → gain 0 on the same running tap. Let the ring drain first,
        // then require the capture to keep flowing while nothing new reaches
        // the output buffer. `pimt` must stay clear: a pimt'd process can stop
        // feeding the tap, which the watchdog would read as a dead reroute.
        mixer.toggleMuted(for: key)
        try await Task.sleep(for: .milliseconds(600))
        let mutedStats = try XCTUnwrap(mixer.engineStats, "mute tore down the tap")
        let capturedAtMute = mutedStats.capturedNonzero
        let playedAtMute = mutedStats.playedNonzero
        try await Task.sleep(for: .milliseconds(600))
        let heldStats = try XCTUnwrap(mixer.engineStats, "mute tore down the tap")
        XCTAssertGreaterThan(
            heldStats.capturedNonzero, capturedAtMute,
            "capture should keep flowing while muted")
        XCTAssertGreaterThan(
            heldStats.played, mutedStats.played,
            "playback IOProc should keep running while muted")
        XCTAssertEqual(
            heldStats.playedNonzero, playedAtMute,
            "muted gain must not add audio to the output buffer")

        let object = try XCTUnwrap(row.processObjectIDs.first)
        var mutedAddress = AppVolumeMixer.address(
            AudioObjectPropertySelector(0x70696D74)) // 'pimt'
        var muted: UInt32 = 0
        var mutedSize = UInt32(MemoryLayout<UInt32>.size)
        XCTAssertEqual(
            AudioObjectGetPropertyData(object, &mutedAddress, 0, nil, &mutedSize, &muted),
            noErr)
        XCTAssertEqual(muted, 0, "pimt should stay clear when the tap path handles mute")

        // Unmute + back to unity → the whole pipeline released.
        mixer.toggleMuted(for: key)
        mixer.setVolume(1, for: key)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(mixer.engineStats, "engine kept running at unity gain")

        // Mute from unity starts a fresh engine. The slot must be seeded at
        // gain 0 before the IOProc starts: no buffer may reach the device at
        // unity while the engine spins up.
        mixer.toggleMuted(for: key)
        try await Task.sleep(for: .milliseconds(800))
        let coldMute = try XCTUnwrap(mixer.engineStats, "mute at unity did not start the tap")
        XCTAssertGreaterThan(coldMute.captured, 0, "taps delivered no audio")
        XCTAssertEqual(
            coldMute.playedNonzero, 0,
            "mute at unity leaked audio before the gain landed")

        mixer.resetToDefault(for: key)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(mixer.engineStats, "engine kept running after reset")
    }
}
