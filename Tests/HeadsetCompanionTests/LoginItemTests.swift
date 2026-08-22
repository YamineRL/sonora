import ServiceManagement
import XCTest
@testable import HeadsetCompanion

/// Covers the decisions around the login item — what each SMAppService status
/// means for the switch and the hint under it, and whether a legacy
/// LaunchAgent is still in the way. Registering itself touches the user's
/// account and is deliberately not exercised here.
final class LoginItemTests: XCTestCase {

    func testOnlyEnabledCountsAsOn() {
        XCTAssertTrue(LoginItemPolicy.isEnabled(.enabled))
        XCTAssertFalse(LoginItemPolicy.isEnabled(.notRegistered))
        // Registered but blocked is *not* on: the app won't start at login
        // until the user approves it, so the switch must not claim otherwise.
        XCTAssertFalse(LoginItemPolicy.isEnabled(.requiresApproval))
        XCTAssertFalse(LoginItemPolicy.isEnabled(.notFound))
    }

    func testOnlyApprovalPointsAtSystemSettings() {
        XCTAssertTrue(LoginItemPolicy.needsApproval(.requiresApproval))
        for status: SMAppService.Status in [.enabled, .notRegistered, .notFound] {
            XCTAssertFalse(LoginItemPolicy.needsApproval(status), "\(status.rawValue)")
        }
    }

    func testOrdinaryStatesSaySilentAndDeadEndsExplain() {
        XCTAssertNil(LoginItemPolicy.message(for: .enabled))
        XCTAssertNil(LoginItemPolicy.message(for: .notRegistered))
        XCTAssertEqual(LoginItemPolicy.message(for: .requiresApproval)?
            .contains("System Settings"), true)
        XCTAssertEqual(LoginItemPolicy.message(for: .notFound)?
            .contains("Applications"), true)
    }

    func testSMAppServiceErrorsGainTheLocationHint() {
        let sm = NSError(domain: "SMAppServiceErrorDomain", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Operation not permitted."])
        let text = LoginItemPolicy.describe(sm)
        XCTAssertTrue(text.contains("Operation not permitted."), text)
        XCTAssertTrue(text.contains("Applications"), text)

        let other = NSError(domain: NSPOSIXErrorDomain, code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "No such file."])
        XCTAssertEqual(LoginItemPolicy.describe(other), "No such file.")
    }

    func testStatusNamesAreDistinct() {
        let names = [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound]
            .map(LoginItemPolicy.name)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
    }

    // MARK: - Legacy LaunchAgent

    func testLegacyPlistPathMatchesTheInstallerScript() {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(LegacyLaunchAgent.plistURL(home: home).path,
                       "/Users/tester/Library/LaunchAgents/io.sonora.headsetcompanion.plist")
    }

    func testLegacyPlistIsDetectedOnlyWhenPresent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-loginitem-tests-\(UUID().uuidString)")
        let agents = dir.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plist = LegacyLaunchAgent.plistURL(home: dir)
        XCTAssertFalse(LegacyLaunchAgent.exists(at: plist))
        try "<plist/>".write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertTrue(LegacyLaunchAgent.exists(at: plist))
    }

    /// The pid decides whether the agent can be booted out without killing
    /// the running app, so it has to be read out of `launchctl print` exactly.
    func testPidIsReadFromLaunchctlPrint() {
        let loaded = """
        io.sonora.headsetcompanion = {
        \tactive count = 1
        \tpath = /Users/tester/Library/LaunchAgents/io.sonora.headsetcompanion.plist
        \tstate = running
        \tpid = 4213
        \tprogram = /Applications/HeadsetCompanion.app/Contents/MacOS/HeadsetCompanion
        }
        """
        XCTAssertEqual(LegacyLaunchAgent.pid(inLaunchctlPrint: loaded), 4213)
        XCTAssertNil(LegacyLaunchAgent.pid(inLaunchctlPrint:
            "Could not find service \"io.sonora.headsetcompanion\""))
        // A loaded-but-not-running job has no pid line at all.
        XCTAssertNil(LegacyLaunchAgent.pid(inLaunchctlPrint: "\tstate = not running\n\tpath = x"))
    }
}
