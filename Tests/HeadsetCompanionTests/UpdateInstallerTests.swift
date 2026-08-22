import XCTest
@testable import HeadsetCompanion

/// Exercises the bundle swap against a real (tiny) disk image, since that is
/// the step that can leave an installation half-applied.
final class UpdateInstallerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds a UDZO image containing `Name.app` whose Info.plist marker file
    /// holds `marker`, mirroring the layout `make-dmg.sh` produces.
    private func makeDMG(appNamed name: String, marker: String) throws -> URL {
        let stage = root.appendingPathComponent("stage-\(marker)")
        let app = stage.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("Contents/marker.txt"),
                         atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("\(marker).dmg")
        try UpdateInstaller.run("/usr/bin/hdiutil", [
            "create", "-volname", "T\(marker)", "-srcfolder", stage.path,
            "-ov", "-format", "UDZO", dmg.path,
        ])
        return dmg
    }

    func testReplaceSwapsBundleAndLeavesNoScratchDirs() throws {
        let installed = root.appendingPathComponent("HeadsetCompanion.app")
        try FileManager.default.createDirectory(
            at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("Contents/marker.txt"),
                        atomically: true, encoding: .utf8)

        let dmg = try makeDMG(appNamed: "HeadsetCompanion.app", marker: "new")
        try UpdateInstaller.replace(bundleAt: installed, withAppIn: dmg)

        let marker = try String(contentsOf: installed.appendingPathComponent("Contents/marker.txt"),
                                encoding: .utf8)
        XCTAssertEqual(marker, "new", "bundle was not replaced")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".HeadsetCompanion.app") }
        XCTAssertEqual(leftovers, [], "scratch bundles left behind: \(leftovers)")
    }

    func testReplaceKeepsOldBundleWhenImageHasNoApp() throws {
        let installed = root.appendingPathComponent("HeadsetCompanion.app")
        try FileManager.default.createDirectory(
            at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try "old".write(to: installed.appendingPathComponent("Contents/marker.txt"),
                        atomically: true, encoding: .utf8)

        let stage = root.appendingPathComponent("empty-stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try "not an app".write(to: stage.appendingPathComponent("README.txt"),
                               atomically: true, encoding: .utf8)
        let dmg = root.appendingPathComponent("empty.dmg")
        try UpdateInstaller.run("/usr/bin/hdiutil", [
            "create", "-volname", "Tempty", "-srcfolder", stage.path,
            "-ov", "-format", "UDZO", dmg.path,
        ])

        XCTAssertThrowsError(try UpdateInstaller.replace(bundleAt: installed, withAppIn: dmg))
        let marker = try String(contentsOf: installed.appendingPathComponent("Contents/marker.txt"),
                                encoding: .utf8)
        XCTAssertEqual(marker, "old", "failed update must leave the installed bundle intact")
    }
}
