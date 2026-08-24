import XCTest
@testable import HeadsetCompanion

/// Unit tests for the media-key event buffer and the now-playing claim
/// policy. No MediaRemote: `start()` is never called and the claim goes to a
/// recording stub, so the monitor under test is the pure state machine plus
/// its in-memory event buffer.
final class MediaKeyMonitorTests: XCTestCase {

    /// Stand-in for `MPNowPlayingInfoCenter`: records every claim/release.
    private final class SpyClaimer: NowPlayingClaiming {
        private(set) var claims = 0
        private(set) var releases = 0
        /// Claims and releases in order, as `"claim"` / `"release"`.
        private(set) var calls: [String] = []
        /// The `force` flag of every claim, in order.
        private(set) var forced: [Bool] = []

        func claim(force: Bool) {
            claims += 1
            forced.append(force)
            calls.append("claim")
        }

        func release() {
            releases += 1
            calls.append("release")
        }
    }

    private func makeMonitor(
        _ policy: MediaKeyPolicy
    ) -> (MediaKeyMonitor, SpyClaimer) {
        let claimer = SpyClaimer()
        return (MediaKeyMonitor(policy: policy, claimer: claimer), claimer)
    }

    // MARK: - eventType(forCommand:)

    func testEventTypeForEachCommand() {
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .togglePlayPause), "play-pause")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .play), "play")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .pause), "pause")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .next), "next")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .previous), "previous")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .stop), "stop")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .seekForward), "seek-forward")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .seekBackward), "seek-backward")
    }

    /// Regression: macOS pauses the now-playing app when the Bluetooth audio
    /// route is torn down. Folding that into the toggle resumed a video the
    /// user had paused, out loud, on the built-in speakers.
    func testASystemPauseIsNeverAToggle() {
        XCTAssertNotEqual(
            MediaKeyMonitor.eventType(forCommand: .pause), "play-pause",
            "a pause from macOS must not be able to start playback"
        )
    }

    /// Only a real press should open the forced re-claim window: a system
    /// pause arrives mid route-teardown, when hammering the now-playing
    /// claim is exactly what stalls the machine.
    func testOnlyPressesCountAsInteraction() {
        XCTAssertFalse(MediaKeyMonitor.isUserInteraction(.play))
        XCTAssertFalse(MediaKeyMonitor.isUserInteraction(.pause))
        for command in [
            MediaKeyMonitor.RemoteCommand.togglePlayPause, .next, .previous, .stop,
            .seekForward, .seekBackward,
        ] {
            XCTAssertTrue(MediaKeyMonitor.isUserInteraction(command), "\(command.rawValue)")
        }
    }

    func testANonInteractionRecordDoesNotOpenTheFastWindow() {
        let claimer = SpyClaimer()
        let monitor = MediaKeyMonitor(policy: .own, claimer: claimer)
        let start = Date()
        monitor.refreshClaim(now: start)          // first claim, forced
        monitor.record(type: "pause", at: start, interaction: false)
        // Still the idle cadence, so nothing is due 2 s later.
        XCTAssertNil(monitor.reassertDue(now: start.addingTimeInterval(2)))
        XCTAssertEqual(monitor.reassertDue(now: start.addingTimeInterval(46)), false)
    }

    func testEveryHandledCommandMapsToAContractType() {
        // The /events contract only ever carries these type strings.
        let allowed: Set<String> = [
            "play-pause", "play", "pause", "next", "previous", "stop",
            "seek-forward", "seek-backward",
        ]
        for command in MediaKeyMonitor.RemoteCommand.allCases {
            XCTAssertTrue(
                allowed.contains(MediaKeyMonitor.eventType(forCommand: command)),
                "\(command.rawValue) mapped outside the contract"
            )
        }
    }

    // MARK: - Policy from the environment

    func testUnknownPolicyStringFallsBackToAuto() {
        XCTAssertEqual(MediaKeyPolicy(rawValue: "own"), .own)
        XCTAssertEqual(MediaKeyPolicy(rawValue: "passive"), .passive)
        XCTAssertNil(MediaKeyPolicy(rawValue: "nonsense"))
        // No SONORA_MEDIA_KEYS set in the test process → auto.
        XCTAssertEqual(MediaKeyMonitor.policyFromEnvironment(), .auto)
    }

    // MARK: - Event buffer

    func testRecordAssignsIncreasingSequences() {
        let (monitor, _) = makeMonitor(.passive)
        monitor.record(type: "play-pause")
        monitor.record(type: "next")

        let all = monitor.events(since: 0)
        XCTAssertEqual(all.seq, 2)
        XCTAssertEqual(all.events.map(\.seq), [1, 2])
        XCTAssertEqual(all.events.map(\.type), ["play-pause", "next"])
        XCTAssertFalse(all.events[0].at.isEmpty)
    }

    func testEventsSinceFiltersTheTail() {
        let (monitor, _) = makeMonitor(.passive)
        monitor.record(type: "play-pause")
        monitor.record(type: "next")
        monitor.record(type: "previous")

        let tail = monitor.events(since: 2)
        XCTAssertEqual(tail.seq, 3)
        XCTAssertEqual(tail.events.map(\.type), ["previous"])
        XCTAssertTrue(monitor.events(since: 3).events.isEmpty)
        XCTAssertEqual(monitor.events(since: 3).seq, 3)
    }

    func testWaitReturnsEarlyWhenAnEventArrives() {
        let (monitor, _) = makeMonitor(.passive)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            monitor.record(type: "play-pause")
        }
        let started = Date()
        let result = monitor.events(since: 0, waitingUpTo: 5)
        XCTAssertEqual(result.events.map(\.type), ["play-pause"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "should not have waited out the timeout")
    }

    func testWaitTimesOutWithNoEvents() {
        let (monitor, _) = makeMonitor(.passive)
        let started = Date()
        let result = monitor.events(since: 0, waitingUpTo: 0.3)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertEqual(result.seq, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25)
    }

    func testWaitReturnsImmediatelyWhenEventsAlreadyExist() {
        let (monitor, _) = makeMonitor(.passive)
        monitor.record(type: "next")
        let started = Date()
        let result = monitor.events(since: 0, waitingUpTo: 5)
        XCTAssertEqual(result.events.map(\.type), ["next"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: - Claim policy (pure decision)

    func testPassivePolicyNeverClaims() {
        let (monitor, _) = makeMonitor(.passive)
        XCTAssertFalse(monitor.shouldClaim())
        monitor.noteConsumerSeen()
        XCTAssertFalse(monitor.shouldClaim())
    }

    func testOwnPolicyAlwaysClaims() {
        let (monitor, _) = makeMonitor(.own)
        XCTAssertTrue(monitor.shouldClaim())
    }

    func testAutoPolicyClaimsOnlyWhileAConsumerIsPresent() {
        let (monitor, _) = makeMonitor(.auto)
        XCTAssertFalse(monitor.shouldClaim(), "no consumer yet — the browser keeps the keys")

        monitor.noteConsumerSeen()
        XCTAssertTrue(monitor.shouldClaim())

        let stale = Date().addingTimeInterval(MediaKeyMonitor.consumerWindow + 1)
        XCTAssertFalse(monitor.shouldClaim(now: stale), "consumer window must expire")
    }

    // MARK: - Source gate

    func testAutoPolicyDoesNotClaimWhenTheBrowserHasNoMediaSources() {
        let (monitor, _) = makeMonitor(.auto)
        monitor.noteConsumerSeen(sources: 0)
        XCTAssertFalse(
            monitor.shouldClaim(),
            "nothing to control: holding the role only costs MediaRemote broadcasts"
        )

        monitor.noteConsumerSeen(sources: 2)
        XCTAssertTrue(monitor.shouldClaim(), "a media tab appeared — take the keys back")
    }

    func testAutoPolicyClaimsWhenTheConsumerReportsNoCountAtAll() {
        let (monitor, _) = makeMonitor(.auto)
        // An extension older than the source gate never sends `sources`.
        // "Unknown" must behave like the old always-claim, not like zero.
        monitor.noteConsumerSeen(sources: nil)
        XCTAssertTrue(monitor.shouldClaim())
    }

    func testAReportWithoutACountDoesNotEraseAKnownOne() {
        let (monitor, _) = makeMonitor(.auto)
        monitor.noteConsumerSeen(sources: 0)
        XCTAssertFalse(monitor.shouldClaim())
        // A bare /events request (the welcome page probing, say) must not be
        // read as "the browser now has sources".
        monitor.noteConsumerSeen()
        XCTAssertFalse(monitor.shouldClaim())
    }

    func testTheSourceGateStillHonoursTheConsumerWindow() {
        let (monitor, _) = makeMonitor(.auto)
        monitor.noteConsumerSeen(sources: 3)
        let stale = Date().addingTimeInterval(MediaKeyMonitor.consumerWindow + 1)
        XCTAssertFalse(monitor.shouldClaim(now: stale), "sources do not outlive the consumer")
    }

    func testOwnPolicyIgnoresTheSourceGate() {
        let (monitor, _) = makeMonitor(.own)
        monitor.noteConsumerSeen(sources: 0)
        XCTAssertTrue(monitor.shouldClaim(), "`own` is the escape hatch: always the keys")
    }

    func testDroppingToZeroSourcesReleasesTheClaim() {
        let (monitor, claimer) = makeMonitor(.auto)
        let t0 = Date()

        monitor.noteConsumerSeen(sources: 1)
        monitor.refreshClaim(now: t0)
        XCTAssertTrue(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.calls, ["claim"])

        // The last media tab closes: hand the keys back rather than keep
        // re-asserting a role nothing is using.
        monitor.noteConsumerSeen(sources: 0)
        monitor.refreshClaim(now: t0)
        XCTAssertFalse(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.calls, ["claim", "release"])

        // And no heartbeat afterwards, however long the bridge idles.
        monitor.noteConsumerSeen(sources: 0)
        monitor.refreshClaim(now: t0.addingTimeInterval(MediaKeyMonitor.idleReassertInterval * 4))
        XCTAssertEqual(claimer.calls, ["claim", "release"], "no broadcasts while idle")
    }

    // MARK: - Claim state machine (drives the claimer)

    func testMonitorStartsUnclaimed() {
        let (monitor, claimer) = makeMonitor(.auto)
        XCTAssertFalse(monitor.mediaKeysActive)
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(claimer.calls, [])
    }

    func testAutoClaimsWhenAConsumerAppearsAndReleasesWhenTheWindowLapses() {
        let (monitor, claimer) = makeMonitor(.auto)
        let t0 = Date()

        monitor.refreshClaim(now: t0)
        XCTAssertFalse(monitor.mediaKeysActive, "no consumer yet")
        XCTAssertEqual(claimer.calls, [])

        monitor.noteConsumerSeen()
        monitor.refreshClaim(now: t0)
        XCTAssertTrue(monitor.mediaKeysActive)
        XCTAssertTrue(monitor.isActive)
        XCTAssertEqual(claimer.calls, ["claim"])

        // Still inside the window, but idle: a refresh 2 s later is far short
        // of the idle cadence, so it must NOT re-assert. This is the fix for
        // the 2 s now-playing flap that woke ControlCenter, audiomxd and
        // bluetoothd ~30 times a minute.
        monitor.refreshClaim(now: t0.addingTimeInterval(2))
        XCTAssertTrue(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.claims, 1, "idle refresh must not re-assert")
        XCTAssertEqual(claimer.releases, 0)

        // Window lapsed: the keys go back to the system, exactly once.
        let stale = t0.addingTimeInterval(MediaKeyMonitor.consumerWindow + 1)
        monitor.refreshClaim(now: stale)
        XCTAssertFalse(monitor.mediaKeysActive)
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(claimer.releases, 1)
        monitor.refreshClaim(now: stale.addingTimeInterval(2))
        XCTAssertEqual(claimer.releases, 1, "release must not repeat while already released")
        XCTAssertEqual(claimer.claims, 1)
    }

    func testAutoReclaimsAfterAConsumerReturns() {
        let (monitor, claimer) = makeMonitor(.auto)
        let t0 = Date()
        monitor.noteConsumerSeen()
        monitor.refreshClaim(now: t0)
        monitor.refreshClaim(now: t0.addingTimeInterval(MediaKeyMonitor.consumerWindow + 1))
        XCTAssertFalse(monitor.mediaKeysActive)

        monitor.noteConsumerSeen()
        monitor.refreshClaim()
        XCTAssertTrue(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.calls, ["claim", "release", "claim"])
    }

    func testOwnPolicyClaimsWithoutAnyConsumerAndReassertsOnTheIdleCadence() {
        let (monitor, claimer) = makeMonitor(.own)
        let t0 = Date()
        monitor.refreshClaim(now: t0)
        XCTAssertTrue(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.forced, [true], "the first claim fights for the role")

        // Refreshes below the idle cadence are free.
        monitor.refreshClaim(now: t0.addingTimeInterval(2))
        monitor.refreshClaim(now: t0.addingTimeInterval(
            MediaKeyMonitor.idleReassertInterval - 1))
        XCTAssertEqual(claimer.claims, 1)

        // Past the idle cadence: another claim, and it must be forced.
        monitor.refreshClaim(now: t0.addingTimeInterval(MediaKeyMonitor.idleReassertInterval))
        XCTAssertEqual(claimer.claims, 2)
        XCTAssertEqual(
            claimer.forced, [true, true],
            "the idle heartbeat must toggle: an unforced re-publish never takes "
            + "the role back from a browser that is playing, so the keys stayed "
            + "with Brave and zero next/previous reached the bridge for 8 h"
        )
        XCTAssertEqual(claimer.releases, 0)
    }

    func testAPressOpensTheFastForcedCadenceThenItLapses() {
        let (monitor, claimer) = makeMonitor(.own)
        let t0 = Date()
        monitor.refreshClaim(now: t0)
        XCTAssertEqual(claimer.claims, 1)

        // A real key press opens the fast window.
        monitor.record(type: "play-pause", at: t0)
        monitor.refreshClaim(now: t0.addingTimeInterval(MediaKeyMonitor.reassertInterval))
        XCTAssertEqual(claimer.claims, 2)
        XCTAssertEqual(claimer.forced.last, true, "inside the fast window the claim is forced")

        // Once the fast window lapses, the idle cadence applies again: a
        // refresh one fast-interval later is no longer due.
        let idle = t0.addingTimeInterval(MediaKeyMonitor.fastWindow + 1)
        monitor.refreshClaim(now: idle)
        XCTAssertEqual(claimer.claims, 2, "no re-assert until the idle cadence elapses")
    }

    func testReassertDueReportsTheCadence() {
        let (monitor, _) = makeMonitor(.own)
        let t0 = Date()
        monitor.refreshClaim(now: t0)

        XCTAssertNil(monitor.reassertDue(now: t0.addingTimeInterval(2)), "idle and not due")
        XCTAssertEqual(
            monitor.reassertDue(now: t0.addingTimeInterval(MediaKeyMonitor.idleReassertInterval)),
            false, "idle and due -> unforced"
        )

        monitor.record(type: "next", at: t0)
        XCTAssertEqual(
            monitor.reassertDue(now: t0.addingTimeInterval(MediaKeyMonitor.reassertInterval)),
            true, "inside the fast window and due -> forced"
        )
    }

    func testPassivePolicyNeverTouchesTheClaimer() {
        let (monitor, claimer) = makeMonitor(.passive)
        monitor.noteConsumerSeen()
        monitor.refreshClaim()
        monitor.refreshClaim()
        XCTAssertFalse(monitor.mediaKeysActive)
        XCTAssertEqual(claimer.calls, [])
    }

    func testStopReleasesAHeldClaim() {
        let (monitor, claimer) = makeMonitor(.own)
        monitor.refreshClaim()
        XCTAssertTrue(monitor.mediaKeysActive)
        monitor.stop()
        XCTAssertFalse(monitor.mediaKeysActive)
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(claimer.releases, 1)
    }

    func testStopWithoutAClaimReleasesNothing() {
        let (monitor, claimer) = makeMonitor(.passive)
        monitor.stop()
        XCTAssertEqual(claimer.calls, [])
    }
}
