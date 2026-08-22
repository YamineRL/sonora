import AppKit
import Combine
import Foundation

/// Self-updater backed by GitHub Releases.
///
/// Once a day (or when the user clicks *Check for Updates…*) it asks the
/// GitHub API for the latest release of `UpdateFeed.repo`, and if its tag is
/// newer than this bundle's `CFBundleShortVersionString` it downloads the
/// release's `.dmg`, swaps the running bundle for the one inside it, and
/// relaunches. No framework, no appcast, no signing key: the app is shipped
/// unsigned, so the only trust anchor is the GitHub repository itself.
@MainActor
final class Updater: ObservableObject {

    /// UserDefaults key for the "check automatically" switch (default on).
    static let autoCheckKey = "autoCheckForUpdates"
    /// UserDefaults key holding the `Date` of the last completed check.
    static let lastCheckKey = "lastUpdateCheck"
    /// How often the background check runs when automatic checks are on.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateFeed.Release)
        case downloading
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let currentVersion: String
    private var timer: Timer?
    private let session: URLSession

    init(currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         session: URLSession = .shared) {
        self.currentVersion = currentVersion
        self.session = session
        if UserDefaults.standard.object(forKey: Self.autoCheckKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoCheckKey)
        }
    }

    static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
    }

    /// Starts the hourly tick that performs at most one check per
    /// `checkInterval` while automatic checks are enabled. The first check
    /// happens shortly after launch so a fresh install learns about a newer
    /// release without waiting a day.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard Self.autoCheckEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        Task { await check(install: true) }
    }

    /// Queries GitHub. With `install: true` a newer release is installed
    /// straight away (the automatic path); otherwise it is surfaced as
    /// `.available` for the user to confirm.
    func check(install: Bool) async {
        if case .checking = state { return }
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .checking
        do {
            let (data, response) = try await session.data(for: UpdateFeed.latestRequest())
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // 404 = the repo has no published release yet. That is not an
            // error for the user: this build is simply the newest there is.
            if status == 404 {
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                state = .upToDate
                BridgeLog.log("[updater] no published release yet (running \(currentVersion))")
                return
            }
            guard status == 200 else { throw UpdateError.http(status) }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard let release = try UpdateFeed.parse(data) else {
                state = .upToDate
                BridgeLog.log("[updater] latest release has no .dmg asset yet")
                return
            }
            guard UpdateFeed.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                BridgeLog.log("[updater] up to date (\(currentVersion); latest \(release.version))")
                return
            }
            BridgeLog.log("[updater] found \(release.version) (running \(currentVersion))")
            state = .available(release)
            if install { await self.install(release) }
        } catch {
            BridgeLog.log("[updater] check failed: \(error)")
            state = .failed(Self.describe(error))
        }
    }

    /// Downloads the DMG, replaces this bundle with the app inside it and
    /// relaunches. Refuses to run from a read-only location (e.g. straight
    /// out of the DMG) because the swap would fail halfway.
    func install(_ release: UpdateFeed.Release) async {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app",
              FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            state = .failed("Move HeadsetCompanion to Applications to enable updates.")
            return
        }
        state = .downloading
        do {
            let (tmp, _) = try await session.download(for: URLRequest(url: release.dmgURL))
            let dmg = tmp.deletingLastPathComponent().appendingPathComponent("HeadsetCompanion-\(release.version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: tmp, to: dmg)
            state = .installing
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.replace(bundleAt: bundleURL, withAppIn: dmg)
            }.value
            BridgeLog.log("[updater] installed \(release.version); relaunching")
            UpdateInstaller.relaunch(bundleURL)
        } catch {
            BridgeLog.log("[updater] install failed: \(error)")
            state = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.description }
        return (error as NSError).localizedDescription
    }
}

enum UpdateError: Error, CustomStringConvertible {
    case http(Int)
    case noDMG
    case noAppInDMG
    case tool(String, Int32)

    var description: String {
        switch self {
        case .http(let code): return "GitHub answered HTTP \(code)."
        case .noDMG: return "Latest release has no .dmg asset."
        case .noAppInDMG: return "No .app inside the downloaded image."
        case .tool(let name, let code): return "\(name) failed (exit \(code))."
        }
    }
}

// MARK: - Feed (pure, testable)

/// Everything about the release feed that doesn't need the network.
enum UpdateFeed {

    static let repo = "YamineRL/sonora"

    struct Release: Equatable {
        /// Version with any leading "v" stripped, e.g. "1.2.0".
        let version: String
        let dmgURL: URL
        let pageURL: URL?
    }

    static func latestRequest() -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("HeadsetCompanion-updater", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        return req
    }

    /// Parses a `releases/latest` payload. Returns nil when the release has
    /// no `.dmg` asset (e.g. the CI build hasn't uploaded it yet).
    static func parse(_ data: Data) throws -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL?
            let assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard let dmg = p.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        return Release(version: normalize(p.tag_name), dmgURL: dmg.browser_download_url, pageURL: p.html_url)
    }

    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Numeric dotted comparison: "1.10.0" > "1.9.3"; missing components
    /// count as 0; anything after a "-" (pre-release) is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            normalize(v).split(separator: "-").first.map(String.init)?
                .split(separator: ".").map { Int($0) ?? 0 } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Installer (disk + hdiutil)

enum UpdateInstaller {

    /// Mounts `dmg`, copies the first `.app` in it next to `bundleURL`, then
    /// swaps the two with renames so an interrupted install leaves either the
    /// old or the new bundle in place, never half of each.
    static func replace(bundleAt bundleURL: URL, withAppIn dmg: URL) throws {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("hc-update-\(ProcessInfo.processInfo.processIdentifier)")
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInDMG }

        let parent = bundleURL.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(bundleURL.lastPathComponent).update")
        let old = parent.appendingPathComponent(".\(bundleURL.lastPathComponent).old")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        try run("/usr/bin/ditto", [app.path, staged.path])
        // The download never carries a quarantine flag (URLSession doesn't
        // set one), but be explicit so Gatekeeper can't block the relaunch.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        try fm.moveItem(at: bundleURL, to: old)
        do {
            try fm.moveItem(at: staged, to: bundleURL)
        } catch {
            try? fm.moveItem(at: old, to: bundleURL)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Starts the new bundle after this process has exited. Exit code 0 so a
    /// launchd `KeepAlive` with `SuccessfulExit=false` doesn't also restart
    /// it and race for the port.
    static func relaunch(_ bundleURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", bundleURL.path]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.tool((tool as NSString).lastPathComponent, p.terminationStatus)
        }
        return p.terminationStatus
    }
}
