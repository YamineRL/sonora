import XCTest

@testable import HeadsetCompanion

/// The monitor's device selection: which connected headset the bridge reports
/// the battery for. Pure — the readings and the default-output name are
/// injected, so no Bluetooth and no CoreAudio are involved.
final class BatteryMonitorSelectionTests: XCTestCase {

    private typealias Reading = SystemBluetoothReader.DeviceReading

    private let headset = Reading(name: "0XM4🫡", battery: 70, isAudio: true)
    private let airpods = Reading(name: "AirPods Pro", battery: 90, isAudio: true)
    private let keyboard = Reading(name: "Magic Keyboard", battery: 42, isAudio: false)
    private let trackpad = Reading(name: "Magic Trackpad", battery: 55, isAudio: false)

    private func select(
        _ readings: [Reading],
        nameFilter: String? = nil,
        defaultOutputName: String? = nil
    ) -> Reading? {
        BatteryMonitor.selectTarget(
            readings: readings,
            nameFilter: nameFilter,
            defaultOutputName: defaultOutputName
        )
    }

    // MARK: - 1. $SONORA_BT_NAME

    func testEnvNameFilterWinsOverTheDefaultOutput() {
        XCTAssertEqual(
            select([airpods, headset], nameFilter: "xm4", defaultOutputName: "AirPods Pro"),
            headset
        )
    }

    func testEnvNameFilterIsCaseInsensitiveSubstring() {
        XCTAssertEqual(select([headset, airpods], nameFilter: "airpods pro"), airpods)
        XCTAssertEqual(select([headset, airpods], nameFilter: "AIRPODS"), airpods)
    }

    func testEnvNameFilterIsExclusive() {
        // Set but matching nothing: no other candidate is picked instead.
        XCTAssertNil(select([headset, airpods], nameFilter: "beats"))
    }

    func testEnvNameFilterCanEvenSelectANonAudioDevice() {
        // An explicit override is the user's decision, whatever the device is.
        XCTAssertEqual(select([keyboard], nameFilter: "magic keyboard"), keyboard)
    }

    // MARK: - 2. The current default audio output

    func testDefaultOutputDeviceIsPreferred() {
        XCTAssertEqual(
            select([headset, airpods], defaultOutputName: "AirPods Pro"), airpods
        )
    }

    func testDefaultOutputMatchIsTrimmedAndCaseInsensitive() {
        XCTAssertEqual(
            select([airpods, headset], defaultOutputName: "  0xm4🫡 "), headset
        )
    }

    func testDefaultOutputWinsOverADeviceReportingABattery() {
        let silent = Reading(name: "Beats Studio", battery: nil, isAudio: true)
        XCTAssertEqual(
            select([headset, silent], defaultOutputName: "Beats Studio"), silent
        )
    }

    func testUnknownDefaultOutputFallsThrough() {
        // Built-in speakers are the default output → no Bluetooth name at all.
        XCTAssertEqual(select([headset], defaultOutputName: nil), headset)
    }

    // MARK: - 3. Any connected audio device

    func testFallsBackToAnAudioDeviceReportingABattery() {
        let silent = Reading(name: "Beats Studio", battery: nil, isAudio: true)
        XCTAssertEqual(select([silent, headset]), headset)
    }

    func testFallsBackToAnAudioDeviceWithoutABattery() {
        let silent = Reading(name: "Beats Studio", battery: nil, isAudio: true)
        XCTAssertEqual(select([keyboard, silent]), silent)
    }

    func testNonAudioDevicesAreNeverPicked() {
        XCTAssertNil(select([keyboard, trackpad]))
    }

    func testKeyboardIsNotPickedEvenWhenItIsTheOnlyOneWithABattery() {
        let silent = Reading(name: "Beats Studio", battery: nil, isAudio: true)
        XCTAssertEqual(select([keyboard, silent]), silent)
    }

    func testNoReadingsAtAll() {
        XCTAssertNil(select([]))
        XCTAssertNil(select([], nameFilter: "xm4", defaultOutputName: "0XM4🫡"))
    }

    // MARK: - Name matching

    func testNamesMatchIgnoresCaseAndSurroundingSpace() {
        XCTAssertTrue(BatteryMonitor.namesMatch("0XM4🫡", " 0xm4🫡 "))
        XCTAssertTrue(BatteryMonitor.namesMatch("AirPods Pro", "airpods pro"))
        XCTAssertFalse(BatteryMonitor.namesMatch("AirPods Pro", "AirPods"))
        XCTAssertFalse(BatteryMonitor.namesMatch(nil, "0XM4🫡"))
        XCTAssertFalse(BatteryMonitor.namesMatch("0XM4🫡", nil))
        XCTAssertFalse(BatteryMonitor.namesMatch("  ", "  "))
    }
}

/// The menu bar dots: one per 20 %, rounded up, clamped to 0–5.
final class MenuBarLabelTests: XCTestCase {
    func testFilledDots() {
        XCTAssertEqual(MenuBarLabel.filledDots(level: 0), 0)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 1), 1)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 20), 1)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 30), 2)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 90), 5)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 100), 5)
        XCTAssertEqual(MenuBarLabel.filledDots(level: 250), 5)
        XCTAssertEqual(MenuBarLabel.filledDots(level: -5), 0)
    }
}

extension MenuBarLabelTests {
    /// The status bar copies the label image as pixels, so the rendered
    /// bitmap must actually contain the lit dots (a lazily drawn image can
    /// come out blank there).
    func testImageHasGreenPixels() {
        let image = MenuBarLabel.image(level: 90, style: .dots)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("no bitmap")
        }
        var green = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5, c.greenComponent > c.redComponent + 0.2 {
                    green += 1
                }
            }
        }
        XCTAssertGreaterThan(green, 10)
        XCTAssertFalse(image.isTemplate)
    }
}


extension MenuBarLabelTests {
    /// Writes both styles to $SONORA_LABEL_DUMP_DIR (when set) for eyeballing.
    func testDumpLabelImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["SONORA_LABEL_DUMP_DIR"] else { return }
        for style in BatteryStyle.allCases {
            let image = MenuBarLabel.image(level: 30, style: style)
            let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.max { $0.pixelsWide < $1.pixelsWide }!
            let png = rep.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("label-\(style.rawValue).png"))
        }
    }
}

/// GitHub Releases feed parsing and version comparison (no network).
final class UpdateFeedTests: XCTestCase {
    func testIsNewer() {
        XCTAssertTrue(UpdateFeed.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateFeed.isNewer("v1.10.0", than: "1.9.3"))
        XCTAssertTrue(UpdateFeed.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(UpdateFeed.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateFeed.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateFeed.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertTrue(UpdateFeed.isNewer("1.1.0-beta", than: "1.0.0"))
    }

    func testParsePicksDMGAsset() throws {
        let json = """
        {"tag_name":"v1.2.0","html_url":"https://github.com/x/y/releases/tag/v1.2.0",
         "assets":[{"name":"sonora-extension.zip","browser_download_url":"https://e/z.zip"},
                   {"name":"HeadsetCompanion-1.2.0.dmg","browser_download_url":"https://e/a.dmg"}]}
        """
        let r = try XCTUnwrap(UpdateFeed.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "1.2.0")
        XCTAssertEqual(r.dmgURL.absoluteString, "https://e/a.dmg")
    }

    func testParseWithoutDMGIsNil() throws {
        let json = #"{"tag_name":"v1.2.0","assets":[]}"#
        XCTAssertNil(try UpdateFeed.parse(Data(json.utf8)))
    }

    func testLatestRequestTargetsRepo() {
        XCTAssertEqual(UpdateFeed.latestRequest().url?.absoluteString,
                       "https://api.github.com/repos/\(UpdateFeed.repo)/releases/latest")
    }
}

/// The menu bar style a fresh install gets.
final class BatteryStyleDefaultTests: XCTestCase {
    func testFallbackIsDots() {
        XCTAssertEqual(BatteryStyle.fallback, .dots)
    }

    func testUnsetOrUnknownDefaultsToFallback() {
        XCTAssertEqual(BatteryStyle(rawValue: "") ?? .fallback, .dots)
        XCTAssertEqual(BatteryStyle(rawValue: "sparklines") ?? .fallback, .dots)
        XCTAssertEqual(BatteryStyle(rawValue: "percent"), .percent)
    }
}
