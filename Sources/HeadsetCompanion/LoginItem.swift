import Foundation
import ServiceManagement

/// The *Start at login* switch, backed by `SMAppService.mainApp`.
///
/// SMAppService is the only login-item mechanism macOS 13+ shows to the user
/// (System Settings → General → Login Items), which is why it replaces the
/// hand-rolled LaunchAgent for the normal install. It is also the only one
/// that can refuse: registering throws when the bundle sits somewhere macOS
/// won't vouch for (a translocated/quarantined copy run straight from the
/// DMG, or a bundle still in ~/Downloads), and a *successful* registration
/// can still land in `.requiresApproval` when the user has previously denied
/// the app. Both are dead ends the user can only escape if we say so, so
/// every outcome is turned into a sentence for the Settings panel instead of
/// an exception or a silently-off switch.
@MainActor
final class LoginItem: ObservableObject {

    /// The live SMAppService verdict. Read on demand (never mirrored into
    /// UserDefaults): the user can flip this item in System Settings behind
    /// our back, so a cached copy would lie.
    @Published private(set) var status: SMAppService.Status = .notRegistered
    /// A sentence to show under the switch, or nil when there is nothing to
    /// explain. Set from `status` or from a thrown registration error.
    @Published private(set) var message: String?

    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
        refresh()
    }

    var isEnabled: Bool { LoginItemPolicy.isEnabled(status) }

    /// Whether to point the user at System Settings — the one state they
    /// cannot resolve from inside this app.
    var needsApproval: Bool { LoginItemPolicy.needsApproval(status) }

    /// Re-reads the real status. Called whenever the Settings panel appears,
    /// so the switch reflects System Settings rather than our last action.
    func refresh() {
        status = service.status
        message = LoginItemPolicy.message(for: status)
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    /// Registers the app as a login item, first retiring the legacy
    /// LaunchAgent: both would start the app at login and the second one to
    /// come up dies on the exclusive bridge port.
    func register() {
        LegacyLaunchAgent.remove()
        do {
            try service.register()
            refresh()
            BridgeLog.log("[loginitem] registered (status \(LoginItemPolicy.name(status)))")
        } catch {
            fail(error, doing: "enable")
        }
    }

    func unregister() {
        do {
            try service.unregister()
            refresh()
            BridgeLog.log("[loginitem] unregistered (status \(LoginItemPolicy.name(status)))")
        } catch {
            fail(error, doing: "disable")
        }
    }

    /// A failed call leaves `status` at whatever macOS still reports, so the
    /// switch snaps back to the truth and the reason is shown beside it.
    private func fail(_ error: Error, doing verb: String) {
        BridgeLog.log("[loginitem] \(verb) failed: \(error)")
        status = service.status
        message = LoginItemPolicy.describe(error)
    }
}

// MARK: - Policy (pure, testable)

/// Everything about the login item that is a decision rather than a call into
/// ServiceManagement, kept separate because `SMAppService` itself does real
/// things to the user's account and cannot be exercised in a unit test.
enum LoginItemPolicy {

    static func isEnabled(_ status: SMAppService.Status) -> Bool { status == .enabled }

    static func needsApproval(_ status: SMAppService.Status) -> Bool { status == .requiresApproval }

    /// What to show under the switch. `.notRegistered` and `.enabled` are the
    /// two ordinary states and say nothing; the rest are dead ends that need
    /// a next step spelled out.
    static func message(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Waiting for approval in System Settings → General → Login Items."
        case .notFound:
            return "macOS can't register this copy. Move HeadsetCompanion to Applications and try again."
        @unknown default:
            return nil
        }
    }

    /// Human-readable failure text for a thrown `register`/`unregister`.
    /// SMAppService's own message is terse ("Operation not permitted") and
    /// the cause is nearly always the bundle's location, so say that too.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "SMAppServiceErrorDomain" {
            return "\(ns.localizedDescription) Move HeadsetCompanion to Applications and open it from there."
        }
        return ns.localizedDescription
    }

    /// Log-friendly name; `SMAppService.Status` has no useful description.
    static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}

// MARK: - Legacy LaunchAgent

/// Retires the `install-launch-agent.sh` LaunchAgent when SMAppService takes
/// over, so only one mechanism starts the app at login. Two would race for
/// the bridge's exclusive TCP port and one of them would exit on bind.
enum LegacyLaunchAgent {

    /// Label written by `install-launch-agent.sh`.
    static let label = "io.sonora.headsetcompanion"

    static func plistURL(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Removes the plist, then boots the job out — but only when the job is
    /// somebody else. If launchd started *this* process, booting it out would
    /// kill the app under the user's cursor mid-click; the plist is already
    /// gone by then, so the agent simply doesn't come back at the next login,
    /// which is all the handover needs.
    static func remove(plist: URL = plistURL()) {
        guard exists(at: plist) else { return }
        do {
            try FileManager.default.removeItem(at: plist)
            BridgeLog.log("[loginitem] removed legacy LaunchAgent \(plist.path)")
        } catch {
            BridgeLog.log("[loginitem] could not remove legacy LaunchAgent: \(error)")
        }
        let target = "gui/\(getuid())/\(label)"
        let running = pid(inLaunchctlPrint: launchctl(["print", target]))
        guard running != ProcessInfo.processInfo.processIdentifier else {
            BridgeLog.log("[loginitem] legacy agent owns this process; leaving it running until quit")
            return
        }
        _ = launchctl(["bootout", target])
        BridgeLog.log("[loginitem] booted out legacy agent \(target)")
    }

    /// The `pid = 1234` line of `launchctl print`, or nil when the job isn't
    /// loaded (or isn't running).
    static func pid(inLaunchctlPrint output: String) -> Int32? {
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "pid" else { continue }
            return Int32(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
