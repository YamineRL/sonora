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
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .play), "play-pause")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .pause), "play-pause")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .next), "next")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .previous), "previous")
        XCTAssertEqual(MediaKeyMonitor.eventType(forCommand: .stop), "stop")
    }

    func testEveryHandledCommandMapsToAContractType() {
        // The /events contract only ever carries these four type strings.
        let allowed: Set<String> = ["play-pause", "next", "previous", "stop"]
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
        monitor.refreshClaim(now: t0.addingTimeInterval(30))
        XCTAssertEqual(claimer.claims, 1)

        // Past the idle cadence: one unforced heartbeat.
        monitor.refreshClaim(now: t0.addingTimeInterval(MediaKeyMonitor.idleReassertInterval))
        XCTAssertEqual(claimer.claims, 2)
        XCTAssertEqual(claimer.forced, [true, false], "the idle heartbeat must not toggle")
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
