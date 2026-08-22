import Foundation
import XCTest

@testable import HeadsetCompanion

final class SystemBluetoothReaderTests: XCTestCase {

    // A trimmed capture of `system_profiler SPBluetoothDataType -xml` on a
    // Mac with one connected headset.
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <array>
    <dict>
    <key>_dataType</key>
    <string>SPBluetoothDataType</string>
    <key>_items</key>
    <array>
    <dict>
    <key>device_connected</key>
    <array>
    <dict>
    <key>0XM4🫡</key>
    <dict>
    <key>device_address</key>
    <string>AC:80:0A:DC:9A:F0</string>
    <key>device_batteryLevelMain</key>
    <string>100 %</string>
    <key>device_minorType</key>
    <string>Headset</string>
    </dict>
    </dict>
    </array>
    <key>device_not_connected</key>
    <array>
    <dict>
    <key>iPhone 123</key>
    <dict>
    <key>device_address</key>
    <string>44:F2:1B:98:7C:C3</string>
    <key>device_minorType</key>
    <string>Phone</string>
    </dict>
    </dict>
    </array>
    </dict>
    </array>
    </dict>
    </array>
    </plist>
    """

    func testParsesConnectedDeviceAndBattery() {
        let readings = SystemBluetoothReader.parseConnected(
            Data(sample.utf8)
        )
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.name, "0XM4🫡")
        XCTAssertEqual(readings.first?.battery, 100)
    }

    func testIgnoresNotConnectedDevices() {
        let readings = SystemBluetoothReader.parseConnected(
            Data(sample.utf8)
        )
        XCTAssertFalse(readings.contains { $0.name == "iPhone 123" })
    }

    func testDeviceWithoutBatteryYieldsNil() {
        let xml = """
        <plist version="1.0"><array><dict><key>_items</key><array><dict>
        <key>device_connected</key><array><dict>
        <key>SomeMouse</key><dict>
        <key>device_address</key><string>AA:BB:CC:DD:EE:FF</string>
        </dict></dict></array>
        </dict></array></dict></array></plist>
        """
        let readings = SystemBluetoothReader.parseConnected(Data(xml.utf8))
        XCTAssertEqual(readings.count, 1)
        XCTAssertNil(readings.first?.battery)
    }

    func testEmptyOutputReturnsEmpty() {
        XCTAssertTrue(SystemBluetoothReader.parseConnected(Data()).isEmpty)
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(
            SystemBluetoothReader.parseConnected(
                Data("not a plist at all".utf8)
            ).isEmpty
        )
    }

    func testBatteryLevelParsing() {
        XCTAssertEqual(
            SystemBluetoothReader.batteryLevel(from: ["device_batteryLevelMain": "42 %"]),
            42
        )
        XCTAssertNil(
            SystemBluetoothReader.batteryLevel(from: ["device_batteryLevelMain": "n/a"])
        )
        XCTAssertEqual(
            SystemBluetoothReader.batteryLevel(from: ["device_batteryLevelMain": "100 %"]),
            100
        )
        XCTAssertNil(SystemBluetoothReader.batteryLevel(from: [:]))
    }

    func testAudioDevicesAreFlagged() {
        let readings = SystemBluetoothReader.parseConnected(Data(sample.utf8))
        XCTAssertEqual(readings.first?.isAudio, true) // device_minorType "Headset"
    }

    func testAudioTypeDetection() {
        XCTAssertTrue(SystemBluetoothReader.isAudioType(from: ["device_minorType": "Headset"]))
        XCTAssertTrue(SystemBluetoothReader.isAudioType(from: ["device_minorType": "Headphones"]))
        XCTAssertTrue(SystemBluetoothReader.isAudioType(from: ["device_majorType": "Audio"]))
        XCTAssertFalse(SystemBluetoothReader.isAudioType(from: ["device_minorType": "Keyboard"]))
        XCTAssertFalse(SystemBluetoothReader.isAudioType(from: ["device_minorType": "Mouse"]))
        XCTAssertFalse(SystemBluetoothReader.isAudioType(from: [:]))
    }
}

/// The IOBluetooth reader's pure parts: the per-device battery selection rule
/// and the merge with the `system_profiler` readings. No real Bluetooth — the
/// readings are injected.
final class IOBluetoothReaderTests: XCTestCase {

    private typealias Reading = SystemBluetoothReader.DeviceReading

    // MARK: - Selection rule

    func testSingleWinsWhenPositive() {
        XCTAssertEqual(
            IOBluetoothReader.selectBattery(single: 70, left: 0, right: 0), 70
        )
        // Even when left/right also report, `single` is the headset's own
        // level (this is the WH-1000XM4 case observed on this Mac).
        XCTAssertEqual(
            IOBluetoothReader.selectBattery(single: 70, left: 90, right: 80), 70
        )
    }

    func testFallsBackToLowerOfLeftAndRight() {
        XCTAssertEqual(
            IOBluetoothReader.selectBattery(single: 0, left: 90, right: 80), 80
        )
        XCTAssertEqual(
            IOBluetoothReader.selectBattery(single: nil, left: 40, right: 55), 40
        )
    }

    func testAllZeroOrMissingIsUnknown() {
        XCTAssertNil(IOBluetoothReader.selectBattery(single: 0, left: 0, right: 0))
        XCTAssertNil(IOBluetoothReader.selectBattery(single: nil, left: nil, right: nil))
        // A half-reporting pair is not trustworthy.
        XCTAssertNil(IOBluetoothReader.selectBattery(single: 0, left: 90, right: 0))
    }

    func testOutOfRangeValuesRejected() {
        XCTAssertNil(IOBluetoothReader.selectBattery(single: 101, left: 0, right: 0))
        XCTAssertNil(IOBluetoothReader.selectBattery(single: -1, left: 0, right: 0))
        XCTAssertEqual(
            IOBluetoothReader.selectBattery(single: 100, left: 0, right: 0), 100
        )
    }

    // MARK: - Merge rule

    func testIOBluetoothLevelWinsOverProfiler() {
        let merged = SystemBluetoothReader.merged(
            ioBluetooth: [Reading(name: "0XM4🫡", battery: 70)],
            systemProfiler: [Reading(name: "0XM4🫡", battery: 100)]
        )
        XCTAssertEqual(merged, [Reading(name: "0XM4🫡", battery: 70)])
    }

    func testProfilerFillsInWhenIOBluetoothHasNoLevel() {
        let merged = SystemBluetoothReader.merged(
            ioBluetooth: [Reading(name: "0XM4🫡", battery: nil)],
            systemProfiler: [Reading(name: "0XM4🫡", battery: 55)]
        )
        XCTAssertEqual(merged, [Reading(name: "0XM4🫡", battery: 55)])
    }

    func testNeitherReaderHasALevel() {
        let merged = SystemBluetoothReader.merged(
            ioBluetooth: [Reading(name: "0XM4🫡", battery: nil)],
            systemProfiler: [Reading(name: "0XM4🫡", battery: nil)]
        )
        XCTAssertEqual(merged, [Reading(name: "0XM4🫡", battery: nil)])
    }

    func testProfilerOnlyDevicesAreKept() {
        let merged = SystemBluetoothReader.merged(
            ioBluetooth: [Reading(name: "0XM4🫡", battery: 70)],
            systemProfiler: [Reading(name: "Magic Trackpad", battery: 42)]
        )
        XCTAssertEqual(merged, [
            Reading(name: "0XM4🫡", battery: 70),
            Reading(name: "Magic Trackpad", battery: 42),
        ])
    }

    func testEmptyIOBluetoothLeavesProfilerUntouched() {
        let profiler = [Reading(name: "0XM4🫡", battery: 100)]
        XCTAssertEqual(
            SystemBluetoothReader.merged(ioBluetooth: [], systemProfiler: profiler),
            profiler
        )
    }

    func testEmptyProfilerLeavesIOBluetoothUntouched() {
        let io = [Reading(name: "0XM4🫡", battery: 70)]
        XCTAssertEqual(
            SystemBluetoothReader.merged(ioBluetooth: io, systemProfiler: []),
            io
        )
    }

    func testAudioFlagSurvivesTheMerge() {
        // Either reader saying "audio" is enough.
        XCTAssertEqual(
            SystemBluetoothReader.merged(
                ioBluetooth: [Reading(name: "0XM4🫡", battery: 70, isAudio: false)],
                systemProfiler: [Reading(name: "0XM4🫡", battery: 100, isAudio: true)]
            ),
            [Reading(name: "0XM4🫡", battery: 70, isAudio: true)]
        )
        XCTAssertEqual(
            SystemBluetoothReader.merged(
                ioBluetooth: [Reading(name: "0XM4🫡", battery: nil, isAudio: true)],
                systemProfiler: []
            ),
            [Reading(name: "0XM4🫡", battery: nil, isAudio: true)]
        )
    }
}
