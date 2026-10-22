import CoreAudio
import Foundation
import XCTest

@testable import HeadsetCompanion

/// Live regression check for the Chromium-helper tap failure: device-
/// agnostic `CATapMutedWhenTapped` taps tear the whole stream down on
/// Brave's helper objects, while device-bound taps deliver it. `afplay`
/// taps fine either way, so only a live Chromium process catches a revert.
/// Skips when Brave isn't producing output; ducks it to ~50 % for a few
/// seconds when it runs, then restores.
@MainActor
final class BraveLiveVerifyTests: XCTestCase {

    func testBraveHelperFlowsThroughDeviceBoundTap() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "live Brave tap test is local-only")
        guard #available(macOS 14.2, *) else {
            throw XCTSkip("process objects need macOS 14.2")
        }
        guard AudioOutputController.readDefaultOutputDevice() != kAudioObjectUnknown else {
            throw XCTSkip("no default output device")
        }
        let mixer = AppVolumeMixer()
        var row: MixerApp?
        for _ in 0..<20 where row == nil {
            row = mixer.apps.first { $0.key == "com.brave.Browser" && !$0.processObjectIDs.isEmpty }
            if row == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        guard let brave = row else {
            throw XCTSkip("Brave is not producing audio right now")
        }
        defer {
            mixer.resetToDefault(for: brave.key)
        }

        mixer.setVolume(0.5, for: brave.key)
        try await Task.sleep(for: .seconds(4))

        let stats = try XCTUnwrap(mixer.engineStats, "engine did not start for Brave")
        XCTAssertGreaterThan(stats.captured, 0, "tap delivered no buffers")
        XCTAssertGreaterThan(stats.capturedNonzero, 0, "tap delivered only zeros — reroute dead")
        XCTAssertGreaterThan(stats.playedNonzero, 0, "nonzero never reached the device")
    }
}
