import CoreAudio
import XCTest

@testable import HeadsetCompanion

/// The mixer's pure logic: which processes become rows and when a row is on
/// the tap path. No CoreAudio calls — these run anywhere.
final class AppVolumeMixerTests: XCTestCase {

    private func app(volume: Float, muted: Bool = false) -> MixerApp {
        MixerApp(
            key: "com.example.app", name: "Example", icon: nil,
            volume: volume, muted: muted, processObjectIDs: []
        )
    }

    // MARK: - Helper-bundle collapse

    func testHelperSuffixesResolveToParentBundle() {
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "com.google.Chrome.helper"),
            "com.google.Chrome")
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "com.google.Chrome.helper.Renderer"),
            "com.google.Chrome")
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "com.tinyspeck.slackmacgap.helper"),
            "com.tinyspeck.slackmacgap")
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "org.mozilla.firefox.GeckoMediaPlugin"),
            "org.mozilla.firefox")
    }

    func testPlainBundlePassesThrough() {
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "us.zoom.xos"), "us.zoom.xos")
        XCTAssertEqual(
            AppVolumeMixer.parentBundleID(of: "com.spotify.client"), "com.spotify.client")
    }

    func testThisAppIsHiddenFromTheMixer() {
        XCTAssertTrue(AppVolumeMixer.hiddenBundles.contains("io.sonora.headsetcompanion"))
    }

    // MARK: - Row state

    func testMutedCoversBothTheFlagAndZeroVolume() {
        XCTAssertTrue(app(volume: 0.4, muted: true).effectivelyMuted)
        XCTAssertTrue(app(volume: 0).effectivelyMuted)
        XCTAssertFalse(app(volume: 0.4).effectivelyMuted)
    }

    /// Inside ±2 % of unity the row stays on the native path. Mute is a tap
    /// state now (gain 0), not a `pimt` write — that is what makes the icon
    /// click actually silence apps whose pimt the HAL ignores.
    func testAdjustedBandAroundUnityGain() {
        XCTAssertFalse(app(volume: 1).adjusted)
        XCTAssertFalse(app(volume: 1.01).adjusted)
        XCTAssertFalse(app(volume: 0.99).adjusted)
        XCTAssertTrue(app(volume: 0.5).adjusted)
        XCTAssertTrue(app(volume: 1.5).adjusted)
        XCTAssertTrue(app(volume: 0.5, muted: true).adjusted)
        XCTAssertTrue(app(volume: 1, muted: true).adjusted)
        XCTAssertTrue(app(volume: 0).adjusted)
    }

    /// The gain slot carries the user's level, except that mute (or zero)
    /// is silence — not whatever the slider happened to be at.
    func testGainIsZeroWhenMuted() {
        XCTAssertEqual(app(volume: 0.5).gain, 0.5)
        XCTAssertEqual(app(volume: 1.5).gain, 1.5)
        XCTAssertEqual(app(volume: 0.5, muted: true).gain, 0)
        XCTAssertEqual(app(volume: 1, muted: true).gain, 0)
        XCTAssertEqual(app(volume: 0).gain, 0)
    }

    /// The reset control is enabled exactly when the row is NOT on the native
    /// path. Unity within the band counts as default; muted at unity does not.
    func testDefaultStateMatchesResetTarget() {
        XCTAssertTrue(app(volume: 1).isDefault)
        XCTAssertTrue(app(volume: 1.01).isDefault)
        XCTAssertTrue(app(volume: 0.99).isDefault)
        XCTAssertFalse(app(volume: 0.5).isDefault)
        XCTAssertFalse(app(volume: 1.5).isDefault)
        XCTAssertFalse(app(volume: 1, muted: true).isDefault)
        XCTAssertFalse(app(volume: 0).isDefault)
    }
    // MARK: - Tap-flow classification

    private func classify(
        total: UInt64, nonzero: UInt64,
        state: inout AppVolumeMixer.TapFlow,
        now: Date
    ) -> AppVolumeMixer.TapAction {
        AppVolumeMixer.classifyTap(
            total: total, nonzero: nonzero, state: &state, now: now,
            staleAfter: 10, deadAfter: 6, maxDeadWindows: 2
        )
    }

    /// Signal arriving is the happy path — and it must clear the dead-window
    /// bookkeeping so a later silent stretch starts fresh.
    func testNonzeroArrivalIsFlowingAndResets() {
        var state = AppVolumeMixer.TapFlow()
        state.lastNonzero = 100
        state.lastTotal = 100
        state.deadSince = Date()
        state.deadWindows = 1
        XCTAssertEqual(.flowing, classify(total: 200, nonzero: 150, state: &state, now: Date()))
        XCTAssertTrue(state.everNonzero)
        XCTAssertEqual(0, state.deadWindows)
        XCTAssertNil(state.deadSince)
    }

    /// A tap that keeps handing over zeroed buffers is just quiet inside
    /// the grace window — and stale only after it. This is the route-churn
    /// case: rebuilding re-binds the tap to the live stream.
    func testZeroedBuffersAreQuietThenStale() {
        var state = AppVolumeMixer.TapFlow()
        state.everNonzero = true
        state.lastNonzero = 50
        let t0 = Date()
        state.lastFlowAt = t0
        XCTAssertEqual(.quiet, classify(total: 500, nonzero: 50, state: &state, now: t0))
        state.lastFlowAt = t0
        XCTAssertEqual(
            .stale,
            classify(total: 1000, nonzero: 50, state: &state, now: t0.addingTimeInterval(11)))
    }

    /// The first silent-on-input observation only starts the dead timer;
    /// the window has to actually elapse before it counts as dead.
    func testNoBuffersOnlyArmsTheDeadTimer() {
        var state = AppVolumeMixer.TapFlow()
        let t0 = Date()
        XCTAssertEqual(.quiet, classify(total: 0, nonzero: 0, state: &state, now: t0))
        XCTAssertNotNil(state.deadSince)
        XCTAssertEqual(.quiet, classify(total: 0, nonzero: 0, state: &state, now: t0.addingTimeInterval(5)))
        XCTAssertEqual(0, state.deadWindows)
    }

    /// The Chromium contract: a tap that delivers no stream gets one
    /// rebuild, and if the rebuilt tap is just as dead the process set is
    /// written off — its mute would otherwise keep the app silent forever.
    func testNeverLiveTapIsUnsupportedAfterTwoDeadWindows() {
        var state = AppVolumeMixer.TapFlow()
        let t0 = Date()
        XCTAssertEqual(.quiet, classify(total: 0, nonzero: 0, state: &state, now: t0))
        XCTAssertEqual(
            .deadWindow,
            classify(total: 0, nonzero: 0, state: &state, now: t0.addingTimeInterval(6.5)))
        XCTAssertEqual(1, state.deadWindows)
        XCTAssertEqual(.quiet, classify(total: 0, nonzero: 0, state: &state, now: t0.addingTimeInterval(7)))
        XCTAssertEqual(
            .unsupported,
            classify(total: 0, nonzero: 0, state: &state, now: t0.addingTimeInterval(13)))
    }

    /// A tap that produced signal earlier proves the reroute *can* work, so
    /// dead buffers after that mean "paused or stale" — never a reason to
    /// disable the app's volume control. Each `.stale` consumes the armed
    /// window, so the verdicts alternate arm → stale.
    func testOnceLiveTapNeverBecomesUnsupported() {
        var state = AppVolumeMixer.TapFlow()
        state.everNonzero = true
        state.lastNonzero = 500
        state.lastTotal = 500
        let t0 = Date()
        var sawStale = false
        for i in 0..<8 {
            let action = classify(
                total: 500, nonzero: 500,
                state: &state, now: t0.addingTimeInterval(6.5 * Double(i)))
            XCTAssertNotEqual(.unsupported, action, "window \(i)")
            sawStale = sawStale || action == .stale
        }
        XCTAssertTrue(sawStale)
        XCTAssertEqual(0, state.deadWindows)
    }
}
