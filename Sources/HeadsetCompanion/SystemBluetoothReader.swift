import Foundation
import IOBluetooth

/// Reads battery levels of the Bluetooth devices connected to this Mac from
/// the public `system_profiler SPBluetoothDataType -xml` CLI (no private
/// APIs, no extra entitlements).
///
/// Why this is needed alongside CoreBluetooth: a headset connected over
/// *classic* Bluetooth (A2DP/HFP, the normal audio case) is invisible to the
/// LE central manager — it is not advertising and `retrieveConnectedPeripherals`
/// only sees LE links. The system's own Bluetooth stack still tracks its
/// battery, and `system_profiler` exposes that.
public enum SystemBluetoothReader {

    /// One connected device as reported by the system.
    public struct DeviceReading: Equatable, Codable {
        public let name: String
        public let battery: Int?
        /// Whether the device is an audio one (headset/headphones/speaker),
        /// as opposed to a keyboard, mouse or phone. The monitor only ever
        /// picks an audio device when it has no explicit name to go on.
        public let isAudio: Bool

        public init(name: String, battery: Int?, isAudio: Bool = false) {
            self.name = name
            self.battery = battery
            self.isAudio = isAudio
        }
    }

    // MARK: - Running

    /// Runs `system_profiler` on a background queue and returns readings for
    /// currently *connected* devices. Returns `[]` on any failure (the file
    /// may still be stale/absent — callers should keep last known state).
    public static func readConnected() -> [DeviceReading] {
        guard let xml = runSystemProfiler() else { return [] }
        return parseConnected(xml)
    }

    /// Both system readers in one list: the IOBluetooth device objects first
    /// (they keep reporting when `system_profiler` drops
    /// `device_batteryLevelMain`), with `system_profiler` filling in every
    /// device IOBluetooth has no level for.
    ///
    /// Merge rule (pure, see `merged(ioBluetooth:systemProfiler:)`): per
    /// device name, an IOBluetooth level wins; otherwise the profiler level
    /// is used; devices only the profiler knows about are appended unchanged.
    /// `isAudio` is true when either reader says so.
    public static func readConnectedMerged(freshProcess: Bool = true) -> [DeviceReading] {
        merged(
            ioBluetooth: freshProcess
                ? IOBluetoothReader.readConnectedFresh()
                : IOBluetoothReader.readConnected(),
            systemProfiler: readConnected()
        )
    }

    /// Pure merge of the two system readers (unit-testable).
    static func merged(
        ioBluetooth: [DeviceReading],
        systemProfiler: [DeviceReading]
    ) -> [DeviceReading] {
        var out: [DeviceReading] = []
        var seen = Set<String>()
        for reading in ioBluetooth {
            seen.insert(reading.name)
            let other = systemProfiler.first { $0.name == reading.name }
            let isAudio = reading.isAudio || (other?.isAudio ?? false)
            out.append(DeviceReading(
                name: reading.name,
                battery: reading.battery ?? other?.battery,
                isAudio: isAudio
            ))
        }
        for reading in systemProfiler where !seen.contains(reading.name) {
            out.append(reading)
        }
        return out
    }

    static func runSystemProfiler() -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType", "-xml"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return data
    }

    // MARK: - Parsing (unit-testable)

    /// Parses `SPBluetoothDataType -xml` output.
    ///
    /// Shape: `<plist><array><dict>… "_items": [ { "device_connected":
    /// [ { "0XM4🫡": { "device_batteryLevelMain": "100 %", … } }, … ], … } ]
    /// …</dict></array></plist>`.
    static func parseConnected(_ xml: Data) -> [DeviceReading] {
        guard
            let top = try? PropertyListSerialization.propertyList(
                from: xml, options: [], format: nil
            ) as? [[String: Any]]
        else { return [] }
        for section in top {
            guard let items = section["_items"] as? [[String: Any]] else { continue }
            for item in items {
                guard let connected = item["device_connected"] as? [[String: Any]]
                else { continue }
                var out: [DeviceReading] = []
                for entry in connected {
                    for (name, value) in entry {
                        guard let props = value as? [String: Any] else { continue }
                        out.append(DeviceReading(
                            name: name,
                            battery: batteryLevel(from: props),
                            isAudio: isAudioType(from: props)
                        ))
                    }
                }
                if !out.isEmpty { return out }
            }
        }
        return []
    }

    /// "100 %" → 100. Missing/odd values → nil.
    static func batteryLevel(from props: [String: Any]) -> Int? {
        guard let raw = props["device_batteryLevelMain"] as? String else { return nil }
        let digits = raw.filter { $0.isNumber }
        guard let value = Int(digits), (0...100).contains(value) else { return nil }
        return value
    }

    /// Whether the profiler describes an audio device. `device_majorType` is
    /// "Audio" for headsets and speakers; `device_minorType` is the more
    /// reliably present key ("Headset", "Headphones", "Speaker").
    static func isAudioType(from props: [String: Any]) -> Bool {
        let words = ["audio", "headset", "headphone", "speaker"]
        for key in ["device_majorType", "device_minorType"] {
            guard let raw = (props[key] as? String)?.lowercased() else { continue }
            if words.contains(where: raw.contains) { return true }
        }
        return false
    }
}

/// Second system reader: asks the Bluetooth stack's own device objects
/// (`IOBluetoothDevice.pairedDevices()`) for the battery percentage macOS
/// shows in its Bluetooth menu.
///
/// Why this exists next to `SystemBluetoothReader`: the XM4 reports its level
/// to macOS through HFP battery indications. When those stop arriving,
/// `system_profiler SPBluetoothDataType -xml` drops the
/// `device_batteryLevelMain` key entirely and the profiler source goes dry —
/// while the `IOBluetoothDevice` object keeps the last level the stack knows,
/// which is exactly what the menu bar keeps showing.
///
/// **These properties are not in the public IOBluetooth headers.**
/// `batteryPercentSingle` / `…Left` / `…Right` / `…Case` / `…Combined` are
/// observed behaviour (macOS 13–26): every paired device responds to them,
/// devices with no known level answer `0`. They are read defensively through
/// KVC — `responds(to:)` is checked first, because KVC on an unknown key
/// raises an Objective-C exception that Swift cannot catch — and
/// `system_profiler` stays in place as the documented fallback.
enum IOBluetoothReader {

    /// Battery keys, in the order we consult them.
    static let singleKey = "batteryPercentSingle"
    static let leftKey = "batteryPercentLeft"
    static let rightKey = "batteryPercentRight"

    /// Argument that makes the bridge binary act as a one-shot reader:
    /// print `readConnected()` as JSON on stdout and exit (see `main.swift`).
    static let helperFlag = "--read-battery"

    /// `readConnected()`, but from a fresh process.
    ///
    /// Why: `IOBluetoothDevice` objects are cached per process and their
    /// battery properties are snapshotted when the object is first created —
    /// a long-running bridge keeps reporting whatever the stack knew at
    /// launch (observed on macOS 26: the menu bar showed 30% while an
    /// 8-hour-old bridge process kept reading "no level" for the same
    /// headset). A short-lived helper process sees the current values, so
    /// the bridge re-executes its own binary with `helperFlag` for every
    /// poll, the way it already spawns `system_profiler`. Falls back to the
    /// in-process read when the helper cannot run.
    static func readConnectedFresh(timeout: TimeInterval = 5) -> [SystemBluetoothReader.DeviceReading] {
        guard let exe = Bundle.main.executableURL else { return [] }
        let task = Process()
        task.executableURL = exe
        task.arguments = [helperFlag]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do {
            try task.run()
        } catch {
            return []
        }
        // Never fall back to `readConnected()` here: inside the GUI process
        // IOBluetooth's coordinator init can block forever against the app's
        // own CoreBluetooth central, and a poll that never returns stops all
        // later polls. A failed helper run just yields no IOBluetooth data.
        // Read on another queue so a helper that never exits cannot block
        // this one on the pipe; IOBluetooth's coordinator init has been seen
        // to hang on a semaphore right after launch.
        var data = Data()
        let reader = DispatchQueue(label: "io.sonora.headsetcompanion.helper-read")
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            BridgeLog.log("[bridge] battery helper timed out after \(Int(timeout))s — skipping IOBluetooth this poll")
            return []
        }
        reader.sync {}
        guard task.terminationStatus == 0,
              let readings = try? JSONDecoder().decode(
                  [SystemBluetoothReader.DeviceReading].self, from: data) else {
            return []
        }
        return readings
    }

    /// Readings for the currently connected paired devices. `[]` when
    /// IOBluetooth has nothing (or is unavailable).
    static func readConnected() -> [SystemBluetoothReader.DeviceReading] {
        guard let paired = IOBluetoothDevice.pairedDevices() else { return [] }
        var out: [SystemBluetoothReader.DeviceReading] = []
        for entry in paired {
            guard let device = entry as? IOBluetoothDevice,
                  device.isConnected() else { continue }
            let name = (device.name ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out.append(SystemBluetoothReader.DeviceReading(
                name: name,
                battery: battery(of: device),
                isAudio: isAudio(device)
            ))
        }
        return out
    }

    /// Whether a device can play sound: the Bluetooth device class says
    /// "Audio", or it publishes an A2DP sink / hands-free service. Keyboards
    /// and mice (class "Peripheral") answer `false`, which is what keeps them
    /// out of the monitor's device selection.
    static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        if device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) {
            return true
        }
        return audioServiceUUID16s.contains { uuid16 in
            device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: uuid16)) != nil
        }
    }

    /// A2DP (sink and source) and HFP (hands-free and audio gateway).
    private static let audioServiceUUID16s: [BluetoothSDPUUID16] = [
        BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassAdvancedAudioDistribution.rawValue),
        BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassAudioSink.rawValue),
        BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassHandsFree.rawValue),
        BluetoothSDPUUID16(kBluetoothSDPUUID16ServiceClassHandsFreeAudioGateway.rawValue),
    ]

    /// Reads the three percentage keys off one device and applies the
    /// selection rule.
    static func battery(of device: NSObject) -> Int? {
        selectBattery(
            single: percent(device, singleKey),
            left: percent(device, leftKey),
            right: percent(device, rightKey)
        )
    }

    /// `single` wins when it is a real level; otherwise a left/right pair
    /// reports the lower of the two (the ear that dies first); everything
    /// else — including the `0` all devices answer when the stack has no
    /// level — is "unknown".
    static func selectBattery(single: Int?, left: Int?, right: Int?) -> Int? {
        if let single, (1...100).contains(single) { return single }
        if let left, let right,
           (1...100).contains(left), (1...100).contains(right) {
            return min(left, right)
        }
        return nil
    }

    /// KVC read guarded against unknown keys (which would raise an ObjC
    /// exception rather than return nil).
    private static func percent(_ device: NSObject, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return (device.value(forKey: key) as? NSNumber)?.intValue
    }
}
