import CoreAudio
import XCTest

@testable import HeadsetCompanion

/// The presentation logic of the sound menu (icons, XM4 matching, labels).
/// Pure functions — no CoreAudio, so these run anywhere.
final class AudioOutputFormattingTests: XCTestCase {

    func testIconFollowsTransportType() {
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeBuiltIn),
            "laptopcomputer")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeBluetooth),
            "headphones")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeBluetoothLE),
            "headphones")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeAggregate),
            "waveform")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeVirtual),
            "waveform")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeUSB),
            "speaker.wave.2")
        XCTAssertEqual(
            AudioOutputFormatting.iconName(forTransportType: kAudioDeviceTransportTypeUnknown),
            "speaker.wave.2")
    }

    func testBridgeDeviceMatchesPublishedName() {
        XCTAssertTrue(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "0XM4🫡",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: " 0xm4🫡 ",
            nameFilter: "xm4"))
    }

    func testBridgeDeviceMatchesBluetoothNameFilterWithoutAReading() {
        XCTAssertTrue(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "WH-1000XM4",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: nil,
            nameFilter: "xm4"))
    }

    func testNonBluetoothNameMatchIsNotTheBridgeDevice() {
        // A USB speaker called "XM4 Dock" is not the headset.
        XCTAssertFalse(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "XM4 Dock",
            transportType: kAudioDeviceTransportTypeUSB,
            bridgeDeviceName: nil,
            nameFilter: "xm4"))
    }

    func testOtherBluetoothDeviceIsNotTheBridgeDevice() {
        XCTAssertFalse(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "AirPods Pro",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: "0XM4🫡",
            nameFilter: "xm4"))
    }

    func testEmptyNamesNeverMatch() {
        XCTAssertFalse(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "   ",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: "0XM4🫡",
            nameFilter: "xm4"))
        XCTAssertFalse(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            bridgeDeviceName: "  ",
            nameFilter: ""))
    }

    func testEveryBluetoothRowWithAReadingGetsALevel() {
        let readings = [
            SystemBluetoothReader.DeviceReading(name: "0XM4🫡", battery: 70, isAudio: true),
            SystemBluetoothReader.DeviceReading(name: "AirPods Pro", battery: 90, isAudio: true),
            SystemBluetoothReader.DeviceReading(name: "Beats", battery: nil, isAudio: true),
        ]
        XCTAssertEqual(AudioOutputFormatting.batteryPercent(
            forDeviceName: " airpods pro ",
            transportType: kAudioDeviceTransportTypeBluetooth,
            readings: readings), 90)
        XCTAssertEqual(AudioOutputFormatting.batteryPercent(
            forDeviceName: "0XM4🫡",
            transportType: kAudioDeviceTransportTypeBluetoothLE,
            readings: readings), 70)
        // Known device, no level yet.
        XCTAssertNil(AudioOutputFormatting.batteryPercent(
            forDeviceName: "Beats",
            transportType: kAudioDeviceTransportTypeBluetooth,
            readings: readings))
        // Not a Bluetooth row, and a row nothing reports on.
        XCTAssertNil(AudioOutputFormatting.batteryPercent(
            forDeviceName: "AirPods Pro",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            readings: readings))
        XCTAssertNil(AudioOutputFormatting.batteryPercent(
            forDeviceName: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBluetooth,
            readings: readings))
    }

    func testBridgeDeviceWithoutANameFilterMatchesOnlyThePublishedName() {
        // No $SONORA_BT_NAME: nothing is guessed from the name.
        XCTAssertTrue(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "AirPods Pro",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: "AirPods Pro",
            nameFilter: nil))
        XCTAssertFalse(AudioOutputFormatting.matchesBridgeDevice(
            deviceName: "WH-1000XM4",
            transportType: kAudioDeviceTransportTypeBluetooth,
            bridgeDeviceName: nil,
            nameFilter: nil))
    }

    func testBatteryLabel() {
        XCTAssertNil(AudioOutputFormatting.batteryLabel(nil))
        XCTAssertEqual(AudioOutputFormatting.batteryLabel(62), "62%")
        XCTAssertEqual(AudioOutputFormatting.batteryLabel(-5), "0%")
        XCTAssertEqual(AudioOutputFormatting.batteryLabel(140), "100%")
    }

    func testBatteryIconBuckets() {
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(nil), "battery.0percent")
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(0), "battery.0percent")
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(20), "battery.25percent")
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(50), "battery.50percent")
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(70), "battery.75percent")
        XCTAssertEqual(AudioOutputFormatting.batteryIconName(100), "battery.100percent")
    }

    func testVolumePercentClampsAndRounds() {
        XCTAssertEqual(AudioOutputFormatting.volumePercent(0), 0)
        XCTAssertEqual(AudioOutputFormatting.volumePercent(0.5), 50)
        XCTAssertEqual(AudioOutputFormatting.volumePercent(0.567), 57)
        XCTAssertEqual(AudioOutputFormatting.volumePercent(-1), 0)
        XCTAssertEqual(AudioOutputFormatting.volumePercent(2), 100)
        XCTAssertEqual(AudioOutputFormatting.volumePercent(.nan), 0)
    }

    func testSpeakerIconReflectsMuteAndZeroVolume() {
        XCTAssertEqual(
            AudioOutputFormatting.speakerIconName(muted: false, volume: 0.4), "speaker.fill")
        XCTAssertEqual(
            AudioOutputFormatting.speakerIconName(muted: true, volume: 0.4), "speaker.slash.fill")
        XCTAssertEqual(
            AudioOutputFormatting.speakerIconName(muted: false, volume: 0), "speaker.slash.fill")
    }
}

/// Read-only checks against the real CoreAudio stack. Skipped when the
/// machine has no output device; never changes the default device or volume.
final class AudioOutputControllerLiveTests: XCTestCase {

    func testEnumeratesOutputDevicesAndReadsTheDefault() throws {
        let devices = AudioOutputController.readOutputDevices()
        try XCTSkipIf(devices.isEmpty, "no CoreAudio output device on this machine")
        for device in devices {
            XCTAssertNotEqual(device.id, kAudioObjectUnknown)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertTrue(AudioOutputController.hasOutputStreams(device: device.id))
        }
        let defaultDevice = AudioOutputController.readDefaultOutputDevice()
        try XCTSkipIf(defaultDevice == kAudioObjectUnknown, "no default output device")
        XCTAssertTrue(devices.contains { $0.id == defaultDevice })
        if let volume = AudioOutputController.readVolume(device: defaultDevice) {
            XCTAssertTrue((0...1).contains(volume), "volume out of range: \(volume)")
        }
    }
}
