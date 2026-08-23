import Foundation
import CoreBluetooth

/// Tracks the battery level of the Bluetooth headset in use, over the system
/// Bluetooth stack and — when the headset offers it — the standard GATT
/// Battery Service (0x180F / 0x2A19).
///
/// Which headset that is, is decided by `selectTarget(readings:…)`: the
/// `$SONORA_BT_NAME` override first, then the Bluetooth device that is the
/// current default audio output, then any connected audio device reporting a
/// battery. Nothing here is model-specific.
///
/// All `@Published` properties are updated on the main queue (the central
/// manager's delegate queue is the main queue).
public final class BatteryMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published state

    /// Most recent battery level (0–100); `nil` before the first reading.
    @Published public private(set) var battery: Int?
    /// Whether the BLE link to the headphones is currently up.
    @Published public private(set) var connected = false
    /// Peripheral name as advertised (trimmed); `nil` when unknown.
    @Published public private(set) var deviceName: String?
    /// ISO 8601 UTC string of the last successful battery reading.
    @Published public private(set) var lastUpdate: String?
    /// Short human line for the menu bar UI.
    @Published public private(set) var statusText = "Scanning…"
    /// Last merged system reading per connected Bluetooth device, so the menu
    /// can label every headset row and not only the bridge's own device.
    @Published public private(set) var systemReadings: [SystemBluetoothReader.DeviceReading] = []

    // MARK: - Constants

    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryCharacteristicUUID = CBUUID(string: "2A19")
    /// How long to wait for a name-matching device before falling back to the
    /// first peripheral that exposes the battery service.
    private static let fallbackDelay: TimeInterval = 2.5
    /// How long to wait before rescan/reconnect after a disconnect.
    private static let rescanDelay: TimeInterval = 3.0
    /// How often to re-read the battery characteristic while connected.
    private static let pollInterval: TimeInterval = 30.0
    /// How long a single discovery scan runs before giving up.
    ///
    /// An unbounded LE scan is the default trap here: a headset linked over
    /// *classic* Bluetooth (A2DP/HFP) never advertises 180F, so the scan
    /// simply never ends and keeps the 2.4 GHz radio busy alongside the audio
    /// link. Scan in short windows and retry instead.
    private static let scanWindow: TimeInterval = 12.0
    /// How long to wait before scanning again after a fruitless window.
    private static let scanRetryInterval: TimeInterval = 300.0

    // MARK: - Internal state

    private var central: CBCentralManager?
    /// Peripheral we are currently trying to connect to / connected to.
    private var target: CBPeripheral?
    /// Identifier of the last accepted device; survives disconnects so we can
    /// prefer it when scanning again.
    private var knownIdentifier: UUID?
    /// Last accepted peripheral, for best-effort direct reconnects.
    private var lastPeripheral: CBPeripheral?
    private var batteryCharacteristic: CBCharacteristic?
    /// Case-insensitive name substring from $SONORA_BT_NAME, when set.
    private var nameFilter: String?
    /// Name of the current default audio output when that output is a
    /// Bluetooth device, `nil` otherwise. Injected (rather than read from
    /// `AudioOutputController` inline) so the selection stays testable and the
    /// monitor keeps no reference to the UI's controller.
    public var defaultBluetoothOutputName: () -> String? = {
        AudioOutputController.defaultBluetoothOutputName()
    }
    private var fallbackCandidate: CBPeripheral?
    private var fallbackWorkItem: DispatchWorkItem?
    /// Stops the current scan window; nil when no scan is running.
    private var scanStopWorkItem: DispatchWorkItem?
    /// Starts the next scan window after a fruitless one.
    private var scanRetryWorkItem: DispatchWorkItem?
    private var pollTimer: Timer?
    /// How often to re-read the system sources (the classic-BT path). A
    /// headset's charge moves by single percent over tens of minutes, and
    /// every poll spawns a helper process, so ten minutes is the interval
    /// that keeps the reading honest without the app working for nothing.
    private static let systemPollInterval: TimeInterval = 600.0
    private var systemTimer: Timer?
    /// Which source currently feeds the published state.
    private enum Source { case none, gatt, system }
    private var source: Source = .none

    // MARK: - Init

    /// Creates the monitor and starts the central manager on the main queue.
    public override init() {
        super.init()
        // CoreBluetooth only runs inside a real app bundle (Info.plist with
        // NSBluetoothAlwaysUsageDescription); a bare `swift run` binary would
        // abort at the framework level. Degrade gracefully there.
        if Bundle.main.bundleIdentifier == nil {
            statusText = "Bluetooth needs the built .app (./build-app.sh)"
            return
        }
        if let envName = ProcessInfo.processInfo.environment["SONORA_BT_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envName.isEmpty {
            nameFilter = envName.lowercased()
        }
        let cm = CBCentralManager(delegate: self, queue: nil) // nil → main queue
        central = cm
        BridgeLog.log("monitor started (bundleId=\(String(describing: Bundle.main.bundleIdentifier)))")
        statusText = cm.state == .poweredOn ? "Scanning…" : "Waiting for Bluetooth…"
        // The system-profiler path is independent of the central manager and
        // covers headsets linked over classic Bluetooth.
        startSystemPolling()
    }

    deinit {
        central?.delegate = nil
    }

    // MARK: - Public API

    /// Re-runs the device selection now — called when the default audio
    /// output changes, so switching headsets switches what `/battery` reports
    /// without waiting for the next scheduled poll.
    public func refreshTarget() {
        systemPoll()
    }

    /// Builds a contract-ready status snapshot from the monitor's state.
    public func currentStatus(port: Int, uptime: Int, mediaKeys: Bool = false) -> BridgeStatus {
        BridgeProtocol.status(
            connected: connected,
            deviceName: deviceName,
            battery: battery,
            lastUpdate: lastUpdate,
            port: port,
            uptime: uptime,
            mediaKeys: mediaKeys
        )
    }

    // MARK: - Scanning & connecting

    private func startScan() {
        guard let central, central.state == .poweredOn, target == nil else { return }
        cancelScanSchedule()
        central.scanForPeripherals(
            withServices: [Self.batteryServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        let stop = DispatchWorkItem { [weak self] in
            guard let self, self.target == nil else { return }
            self.central?.stopScan()
            self.scanStopWorkItem = nil
            let retry = DispatchWorkItem { [weak self] in self?.startScan() }
            self.scanRetryWorkItem = retry
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.scanRetryInterval, execute: retry
            )
        }
        scanStopWorkItem = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanWindow, execute: stop)
    }

    /// Drops any pending scan-window stop / retry (a scan is ending early,
    /// or a new window is starting).
    private func cancelScanSchedule() {
        scanStopWorkItem?.cancel()
        scanStopWorkItem = nil
        scanRetryWorkItem?.cancel()
        scanRetryWorkItem = nil
    }

    private func connect(to peripheral: CBPeripheral, advertisedName: String?) {
        guard target == nil else { return }
        cancelFallback()
        cancelScanSchedule()
        central?.stopScan()
        target = peripheral
        lastPeripheral = peripheral
        knownIdentifier = peripheral.identifier
        peripheral.delegate = self
        if let name = Self.trim(advertisedName), !name.isEmpty {
            deviceName = name
        }
        statusText = "Connecting…"
        central?.connect(peripheral)
    }

    private func considerFallback(_ peripheral: CBPeripheral) {
        guard fallbackCandidate == nil else { return }
        fallbackCandidate = peripheral
        let item = DispatchWorkItem { [weak self] in
            guard let self, let candidate = self.fallbackCandidate, self.target == nil else { return }
            self.connect(to: candidate, advertisedName: candidate.name)
        }
        fallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: item)
    }

    private func cancelFallback() {
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        fallbackCandidate = nil
    }

    /// Handles a peripheral that is already connected to the local Mac
    /// (found via `retrieveConnectedPeripherals`). The name must be one the
    /// monitor is after — the loose "first device with a battery service"
    /// fallback is too risky here (Apple keyboards and mice expose one too).
    private func considerConnected(_ peripheral: CBPeripheral) {
        guard target == nil else { return }
        let name = Self.trim(peripheral.name)
        if let id = knownIdentifier, peripheral.identifier == id {
            connect(to: peripheral, advertisedName: name)
            return
        }
        if acceptsName(name) {
            connect(to: peripheral, advertisedName: name)
        }
    }

    private func resumeConnections() {
        guard target == nil, let central, central.state == .poweredOn else { return }
        for peripheral in central.retrieveConnectedPeripherals(
            withServices: [Self.batteryServiceUUID]
        ) {
            considerConnected(peripheral)
        }
        startScan()
        // Best-effort direct reconnect (works even if the device stopped
        // advertising); the rescan above covers the normal case.
        if let last = lastPeripheral {
            connect(to: last, advertisedName: deviceName)
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BridgeLog.log("[bridge] central state: \(central.state.rawValue) (0=unknown 1=resetting 2=unsupported 3=unauthorized 4=poweredOff 5=poweredOn)")
        switch central.state {
        case .poweredOn:
            statusText = "Scanning…"
            // A headset already linked to this Mac (e.g. paired for audio)
            // stops advertising, so a scan alone never sees it. Pick up
            // anything that is already connected and offers the battery
            // service.
            let already = central.retrieveConnectedPeripherals(
                withServices: [Self.batteryServiceUUID]
            )
            BridgeLog.log("[bridge] retrieveConnectedPeripherals(180F) -> \(already.count) device(s): \(already.map { $0.name ?? "?" })")
            for peripheral in already {
                considerConnected(peripheral)
            }
            startScan()
        case .poweredOff:
            connected = false
            statusText = "Bluetooth is off"
        case .unauthorized:
            connected = false
            statusText = "Bluetooth not authorized"
        case .unsupported:
            connected = false
            statusText = "Bluetooth not supported"
        default:
            statusText = "Waiting for Bluetooth…"
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        BridgeLog.log("[bridge] didDiscover \(peripheral.identifier) name=\(String(describing: advertisementData[CBAdvertisementDataLocalNameKey]))")
        guard target == nil else { return }
        let advertisedName = Self.trim(
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
        )

        // 1. A previously connected device always wins.
        if let id = knownIdentifier, peripheral.identifier == id {
            connect(to: peripheral, advertisedName: advertisedName)
            return
        }
        // 2. Explicit name filter from $SONORA_BT_NAME — exclusive when set.
        if nameFilter != nil {
            if acceptsName(advertisedName) {
                connect(to: peripheral, advertisedName: advertisedName)
            }
            return
        }
        // 3. The headset the system source (or the default audio output)
        //    already points at.
        if acceptsName(advertisedName) {
            connect(to: peripheral, advertisedName: advertisedName)
            return
        }
        // 4. Fallback: first peripheral that exposes the battery service.
        considerFallback(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        BridgeLog.log("[bridge] didConnect \(peripheral.identifier) name=\(String(describing: peripheral.name))")
        guard peripheral.identifier == knownIdentifier else { return }
        connected = true
        if let name = Self.trim(peripheral.name), !name.isEmpty {
            deviceName = name
        }
        statusText = "Discovering battery service…"
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == knownIdentifier else { return }
        connected = false
        if source == .gatt { source = .none }
        stopPolling()
        target = nil
        statusText = "Disconnected, resuming…"
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescanDelay) { [weak self] in
            self?.resumeConnections()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == knownIdentifier else { return }
        target = nil
        statusText = "Reconnect failed, resuming…"
        startScan()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        BridgeLog.log("[bridge] didDiscoverServices error=\(String(describing: error)) services=\(peripheral.services?.map { $0.uuid.uuidString } ?? [])")
        guard peripheral.identifier == knownIdentifier else { return }
        if let error {
            statusText = "Service discovery failed: \(error.localizedDescription)"
        }
        for service in peripheral.services ?? [] where service.uuid == Self.batteryServiceUUID {
            peripheral.discoverCharacteristics([Self.batteryCharacteristicUUID], for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == knownIdentifier else { return }
        for characteristic in service.characteristics ?? []
            where characteristic.uuid == Self.batteryCharacteristicUUID {
            batteryCharacteristic = characteristic
            statusText = "Reading battery…"
            peripheral.readValue(for: characteristic)
            peripheral.setNotifyValue(true, for: characteristic)
            startPolling()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == knownIdentifier,
              characteristic.uuid == Self.batteryCharacteristicUUID,
              error == nil else { return }
        BridgeLog.log("[bridge] didUpdateValue error=\(String(describing: error)) value=\(String(describing: characteristic.value?.map { $0 }))")
        guard let data = characteristic.value, data.count == 1 else { return }
        let level = min(max(Int(data[0]), 0), 100)
        battery = level
        lastUpdate = Self.iso8601Now()
        connected = true
        source = .gatt
        statusText = "Connected — \(level)%"
        Self.persistLastKnown(battery: level)
    }

    // MARK: - Polling

    /// Some devices stop notifying after sleep; re-read every 30 s while up.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.connected,
                  let peripheral = self.target,
                  let characteristic = self.batteryCharacteristic else { return }
            peripheral.readValue(for: characteristic)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        batteryCharacteristic = nil
    }

    // MARK: - System source (classic-BT headsets)

    /// A headset linked to the Mac over classic Bluetooth (A2DP/HFP) is
    /// invisible to the LE central manager, but the system's Bluetooth stack
    /// still tracks its battery — both `IOBluetoothDevice.pairedDevices()`
    /// and `system_profiler` expose it, and the poll merges the two (see
    /// `SystemBluetoothReader.readConnectedMerged()`, needed because the
    /// profiler intermittently drops `device_batteryLevelMain` while the
    /// IOBluetooth objects keep the level). This poller is the primary source
    /// for that case; the GATT path (above) still wins whenever it is
    /// actively reporting.
    private func startSystemPolling() {
        systemTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.systemPollInterval, repeats: true
        ) { [weak self] _ in
            self?.systemPoll()
        }
        RunLoop.main.add(timer, forMode: .common)
        systemTimer = timer
        systemPoll() // first reading immediately
    }

    private var systemReadInFlight = false
    /// The first poll reads in-process: this process is itself fresh, and
    /// spawning the helper during app launch has been seen to hang.
    private func systemPoll() {
        guard !systemReadInFlight else { return }
        systemReadInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let readings = SystemBluetoothReader.readConnectedMerged()
            DispatchQueue.main.async {
                guard let self else { return }
                self.systemReadInFlight = false
                BridgeLog.log(
                    "[bridge] system readings: \(readings.map { "\($0.name)=\($0.battery.map(String.init) ?? "-")" })"
                )
                self.applySystemReadings(readings)
            }
        }
    }

    private func applySystemReadings(_ readings: [SystemBluetoothReader.DeviceReading]) {
        systemReadings = readings
        guard let match = Self.selectTarget(
            readings: readings,
            nameFilter: nameFilter,
            defaultOutputName: defaultBluetoothOutputName()
        ) else {
            if source == .system {
                source = .none
                connected = false
                statusText = "Disconnected, resuming…"
            }
            return
        }
        // The GATT link is fresher, but only while it is the headset the
        // selection still points at — otherwise a device switch (or a
        // disconnect of the GATT device) has to move the report over.
        guard source != .gatt || !Self.namesMatch(deviceName, match.name) else { return }
        source = .system
        connected = true
        deviceName = match.name
        if let level = match.battery {
            battery = level
            lastUpdate = Self.iso8601Now()
            statusText = "Connected — \(level)%"
            Self.persistLastKnown(battery: level)
        } else if let known = Self.lastKnownValue() {
            battery = known.battery
            lastUpdate = known.updatedAt
            statusText = "Connected — \(known.battery)% (last known)"
        } else {
            statusText = "Connected (no battery reported)"
        }
    }

    // MARK: - Device selection (pure)

    /// The case-insensitive name substring the monitor matches on when
    /// `$SONORA_BT_NAME` is set; `nil` otherwise — there is no built-in
    /// model default, the headset is found by what it is, not by its name.
    /// Exposed so the sound menu can mark the same headset in its output list.
    public static var effectiveNameFilter: String? {
        guard let envName = ProcessInfo.processInfo.environment["SONORA_BT_NAME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !envName.isEmpty else { return nil }
        return envName.lowercased()
    }

    /// Picks the headset the bridge reports the battery for, out of the merged
    /// system readings. In priority order:
    ///
    /// 1. `$SONORA_BT_NAME` as a case-insensitive substring, when set;
    /// 2. the Bluetooth device that is the current default audio output
    ///    (its CoreAudio name matched to the Bluetooth device name);
    /// 3. any connected *audio* device, one reporting a battery first.
    ///
    /// Non-audio devices (keyboards, mice, phones) are never picked in 3, so
    /// a Magic Keyboard's battery can't end up on the headphones card.
    static func selectTarget(
        readings: [SystemBluetoothReader.DeviceReading],
        nameFilter: String?,
        defaultOutputName: String?
    ) -> SystemBluetoothReader.DeviceReading? {
        if let nameFilter, !nameFilter.isEmpty {
            let needle = nameFilter.lowercased()
            return readings.first { $0.name.lowercased().contains(needle) }
        }
        if let match = readings.first(where: { namesMatch($0.name, defaultOutputName) }) {
            return match
        }
        let audio = readings.filter(\.isAudio)
        return audio.first { $0.battery != nil } ?? audio.first
    }

    /// Case-insensitive, trimmed equality — the CoreAudio name of a Bluetooth
    /// output and the IOBluetooth device name are the same string up to that.
    static func namesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = trim(lhs)?.lowercased(), let rhs = trim(rhs)?.lowercased() else {
            return false
        }
        return lhs == rhs
    }

    /// Whether a CoreBluetooth peripheral name is one the monitor is after:
    /// the `$SONORA_BT_NAME` substring when set, else the device the system
    /// source already reports or the current Bluetooth default output.
    private func acceptsName(_ name: String?) -> Bool {
        guard let name = Self.trim(name) else { return false }
        if let nameFilter { return name.lowercased().contains(nameFilter) }
        return Self.namesMatch(name, deviceName)
            || Self.namesMatch(name, defaultBluetoothOutputName())
    }

    // MARK: - Helpers

    static func trim(_ string: String?) -> String? {
        guard let string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Last-known battery persistence

    /// The headset's battery should survive app restarts and periods when
    /// system_profiler stops reporting a level: keep serving the last real
    /// reading instead of null.
    private struct LastKnown: Codable {
        let battery: Int
        let updatedAt: String
    }

    private static var lastKnownCache: LastKnown?

    private static var lastKnownURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("HeadsetCompanion/last-known.json")
    }

    private static func lastKnownValue() -> LastKnown? {
        if let cached = lastKnownCache { return cached }
        if let data = try? Data(contentsOf: lastKnownURL),
           let value = try? JSONDecoder().decode(LastKnown.self, from: data) {
            lastKnownCache = value
            return value
        }
        return nil
    }

    private static func persistLastKnown(battery: Int) {
        let value = LastKnown(battery: battery, updatedAt: iso8601Now())
        lastKnownCache = value
        do {
            try FileManager.default.createDirectory(
                at: lastKnownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: lastKnownURL, options: .atomic)
        } catch {
            BridgeLog.log("[bridge] failed to persist last-known battery: \(error)")
        }
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
