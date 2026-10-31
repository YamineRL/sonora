import AudioToolbox
import CoreAudio
import Foundation

/// One CoreAudio device that can play sound (it has at least one output
/// stream), as shown in the menu's *Output* list.
public struct AudioOutputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    /// `kAudioDevicePropertyTransportType` value (`kAudioDeviceTransportTypeBluetooth`, …).
    public let transportType: UInt32

    public init(id: AudioDeviceID, name: String, transportType: UInt32) {
        self.id = id
        self.name = name
        self.transportType = transportType
    }
}

/// Pure presentation logic for the sound menu — no CoreAudio calls, so the
/// tests can cover it on any machine.
public enum AudioOutputFormatting {

    /// SF Symbol for a device row, chosen from its transport type the way
    /// Apple's own Sound menu does it.
    public static func iconName(forTransportType transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "speaker.wave.2.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return "waveform"
        default:
            return "speaker.wave.2"
        }
    }

    /// Whether a transport type is one of the two Bluetooth ones.
    public static func isBluetooth(transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Battery level to show on an output row: the system reading for the
    /// Bluetooth device of that name. `nil` for every non-Bluetooth row and
    /// for Bluetooth devices the system reports no level for — every headset
    /// gets its own label, not just the one the bridge reports on.
    public static func batteryPercent(
        forDeviceName deviceName: String,
        transportType: UInt32,
        readings: [SystemBluetoothReader.DeviceReading]
    ) -> Int? {
        guard isBluetooth(transportType: transportType) else { return nil }
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !device.isEmpty else { return nil }
        return readings.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == device
        }?.battery
    }

    /// Whether an output device row is the headset the bridge reports the
    /// battery for (the one `/battery` answers about): the same name the
    /// `BatteryMonitor` published, or — before that arrives — a Bluetooth
    /// device whose name matches the `$SONORA_BT_NAME` filter when one is set.
    public static func matchesBridgeDevice(
        deviceName: String,
        transportType: UInt32,
        bridgeDeviceName: String?,
        nameFilter: String?
    ) -> Bool {
        let device = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if device.isEmpty { return false }
        if let bridgeDeviceName,
           !bridgeDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bridge = bridgeDeviceName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if device == bridge { return true }
        }
        guard isBluetooth(transportType: transportType) else { return false }
        let needle = nameFilter?.lowercased() ?? ""
        return !needle.isEmpty && device.contains(needle)
    }

    /// Trailing battery label for the headset row ("62%"); `nil` when there
    /// is no reading yet, so the row just shows the name.
    public static func batteryLabel(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        return "\(min(max(percent, 0), 100))%"
    }

    /// SF Symbol for a battery level, matching Apple's five battery glyphs.
    public static func batteryIconName(_ percent: Int?) -> String {
        guard let percent else { return "battery.0percent" }
        switch min(max(percent, 0), 100) {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Scalar volume (0…1) as whole percent, clamped.
    public static func volumePercent(_ scalar: Float) -> Int {
        if scalar.isNaN { return 0 }
        return Int((min(max(scalar, 0), 1) * 100).rounded())
    }

    /// The speaker glyph on the left of the slider — it doubles as the mute
    /// toggle, so it reflects the mute state.
    public static func speakerIconName(muted: Bool, volume: Float) -> String {
        if muted || volumePercent(volume) == 0 { return "speaker.slash.fill" }
        return "speaker.fill"
    }
}

/// The CoreAudio side of the menu: the list of output devices, which one is
/// the system default, and the default device's volume and mute state.
///
/// Everything is published on the main queue (the property listeners are
/// registered against `DispatchQueue.main`), so SwiftUI can bind to it
/// directly. The controller only reads and writes what the user asks for —
/// it never changes the default device or the volume on its own.
public final class AudioOutputController: ObservableObject {

    // MARK: - Published state

    /// Every device with at least one output stream, in CoreAudio order.
    @Published public private(set) var devices: [AudioOutputDevice] = []
    /// `kAudioHardwarePropertyDefaultOutputDevice`.
    @Published public private(set) var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
    /// Scalar volume (0…1) of the current default output device.
    @Published public private(set) var volume: Float = 0
    /// Whether the current default output device is muted.
    @Published public private(set) var muted = false
    /// False when the default device exposes no settable volume (some
    /// digital outputs) — the slider is then disabled.
    @Published public private(set) var volumeSupported = false

    // MARK: - Hooks

    /// Called on the main queue whenever the default output device changes.
    /// The bridge uses it to re-pick the headset it reports the battery for;
    /// the controller itself knows nothing about the monitor.
    public var onDefaultDeviceChange: (() -> Void)?

    // MARK: - Internal state

    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Device the volume/mute listeners are currently attached to.
    private var observedDeviceID: AudioDeviceID = kAudioObjectUnknown

    // MARK: - Init

    public init() {
        refreshDevices()
        refreshDefaultDevice()
        addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in
            self?.refreshDevices()
        }
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.refreshDefaultDevice()
        }
    }

    deinit {
        for (object, address, block) in listenerBlocks {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
    }

    // MARK: - Public API

    /// Re-reads the volume and mute of the current default device. Cheap
    /// enough to call on a timer while the menu is open, as a belt-and-braces
    /// backstop for devices that don't notify.
    public func refreshVolume() {
        let device = defaultDeviceID
        guard device != kAudioObjectUnknown else {
            volumeSupported = false
            return
        }
        if let value = Self.readVolume(device: device) {
            volumeSupported = true
            if abs(value - volume) > 0.0001 { volume = value }
        } else {
            volumeSupported = false
        }
        let isMuted = Self.readMute(device: device)
        if isMuted != muted { muted = isMuted }
    }

    /// Sets the system output volume (0…1). Unmutes when moved off zero, the
    /// way the Sound menu's slider does.
    public func setVolume(_ newValue: Float) {
        let clamped = min(max(newValue, 0), 1)
        volume = clamped
        let device = defaultDeviceID
        guard device != kAudioObjectUnknown else { return }
        Self.writeVolume(clamped, device: device)
        if clamped > 0, muted {
            Self.writeMute(false, device: device)
            muted = false
        }
    }

    public func toggleMute() {
        let device = defaultDeviceID
        guard device != kAudioObjectUnknown else { return }
        let newValue = !muted
        Self.writeMute(newValue, device: device)
        muted = newValue
    }

    /// Makes `device` the system default output.
    public func selectDevice(_ device: AudioOutputDevice) {
        var deviceID = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        if status != noErr {
            BridgeLog.log("[audio] failed to set default output device \(device.name): \(status)")
        }
        refreshDefaultDevice()
    }

    // MARK: - Refresh

    private func refreshDevices() {
        let found = Self.readOutputDevices()
        if found != devices { devices = found }
    }

    private func refreshDefaultDevice() {
        let device = Self.readDefaultOutputDevice()
        let changed = device != defaultDeviceID
        if changed { defaultDeviceID = device }
        observeVolume(of: device)
        refreshVolume()
        if changed { onDefaultDeviceChange?() }
    }

    /// Moves the volume/mute listeners to the new default device.
    private func observeVolume(of device: AudioDeviceID) {
        guard device != observedDeviceID else { return }
        removeListeners(for: observedDeviceID)
        observedDeviceID = device
        guard device != kAudioObjectUnknown else { return }
        for selector in [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyMute
        ] {
            addListener(
                object: device,
                address: Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            ) { [weak self] in
                self?.refreshVolume()
            }
        }
    }

    // MARK: - Listener plumbing

    private func addSystemListener(
        _ selector: AudioObjectPropertySelector,
        handler: @escaping () -> Void
    ) {
        addListener(object: AudioObjectID(kAudioObjectSystemObject),
                    address: Self.address(selector),
                    handler: handler)
    }

    private func addListener(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping () -> Void
    ) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else { return }
        listenerBlocks.append((object, address, block))
    }

    private func removeListeners(for object: AudioObjectID) {
        guard object != kAudioObjectUnknown else { return }
        listenerBlocks.removeAll { entry in
            guard entry.0 == object else { return false }
            var address = entry.1
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, entry.2)
            return true
        }
    }

    // MARK: - CoreAudio reads

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Every device that has at least one output stream.
    public static func readOutputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard hasOutputStreams(device: id), let name = readName(device: id) else { return nil }
            return AudioOutputDevice(id: id, name: name, transportType: readTransportType(device: id))
        }
    }

    static func hasOutputStreams(device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    static func readName(device: AudioDeviceID) -> String? {
        var address = address(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        let trimmed = (name as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func readTransportType(device: AudioDeviceID) -> UInt32 {
        var address = address(kAudioDevicePropertyTransportType)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var transport: UInt32 = kAudioDeviceTransportTypeUnknown
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return transport
    }

    /// Name of the current default output device when it is a Bluetooth one,
    /// `nil` for any other transport (or when there is no default). This is
    /// what tells the bridge which headset is actually in use.
    public static func defaultBluetoothOutputName() -> String? {
        let device = readDefaultOutputDevice()
        guard device != kAudioObjectUnknown,
              AudioOutputFormatting.isBluetooth(
                  transportType: readTransportType(device: device)
              ) else { return nil }
        return readName(device: device)
    }

    public static func readDefaultOutputDevice() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var device = kAudioObjectUnknown
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return kAudioObjectUnknown }
        return device
    }

    /// Virtual main volume when the device has one, otherwise the mean of
    /// channels 1/2 (`kAudioDevicePropertyVolumeScalar` is per-channel on
    /// devices that expose no main channel). `nil` when neither exists.
    static func readVolume(device: AudioDeviceID) -> Float? {
        var mainAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(device, &mainAddress) {
            var size = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            if AudioObjectGetPropertyData(device, &mainAddress, 0, nil, &size, &value) == noErr {
                return Float(value)
            }
        }
        var total: Float = 0
        var channels = 0
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = address(kAudioDevicePropertyVolumeScalar,
                                         scope: kAudioObjectPropertyScopeOutput,
                                         element: channel)
            guard AudioObjectHasProperty(device, &channelAddress) else { continue }
            var size = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            guard AudioObjectGetPropertyData(
                device, &channelAddress, 0, nil, &size, &value
            ) == noErr else { continue }
            total += Float(value)
            channels += 1
        }
        return channels > 0 ? total / Float(channels) : nil
    }

    static func writeVolume(_ newValue: Float, device: AudioDeviceID) {
        var value = Float32(newValue)
        let size = UInt32(MemoryLayout<Float32>.size)
        var mainAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectHasProperty(device, &mainAddress),
           AudioObjectSetPropertyData(device, &mainAddress, 0, nil, size, &value) == noErr {
            return
        }
        for channel in UInt32(1)...UInt32(2) {
            var channelAddress = address(kAudioDevicePropertyVolumeScalar,
                                         scope: kAudioObjectPropertyScopeOutput,
                                         element: channel)
            guard AudioObjectHasProperty(device, &channelAddress) else { continue }
            AudioObjectSetPropertyData(device, &channelAddress, 0, nil, size, &value)
        }
    }

    static func readMute(device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    static func writeMute(_ newValue: Bool, device: AudioDeviceID) {
        var address = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = newValue ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
