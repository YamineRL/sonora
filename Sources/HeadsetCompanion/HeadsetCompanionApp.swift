import AppKit
import Combine
import SwiftUI

/// HeadsetCompanion menu bar app.
///
/// Tracks the Bluetooth headset in use (via `BatteryMonitor`) and serves its
/// battery level as JSON on `http://127.0.0.1:<port>/battery` for the
/// Sonora Media Cockpit Chrome extension. The menu itself is a replacement
/// for Apple's *Sound* menu bar item: volume, output device picker, and each
/// headset's battery on its row.
struct HeadsetCompanionApp: App {

    @StateObject private var monitor: BatteryMonitor
    @StateObject private var mediaKeys: MediaKeyMonitor
    @StateObject private var audio: AudioOutputController
    private let server: BridgeServer
    private let startedAt: Date
    private let statusItem: StatusItemController
    private let updater: Updater

    init() {
        let started = Date()
        let monitor = BatteryMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        // Switching the default output switches which headset the bridge
        // reports on, so the monitor re-picks its device on every change.
        let audio = AudioOutputController()
        audio.onDefaultDeviceChange = { [weak monitor] in monitor?.refreshTarget() }
        _audio = StateObject(wrappedValue: audio)
        let mediaKeys = MediaKeyMonitor()
        _mediaKeys = StateObject(wrappedValue: mediaKeys)
        startedAt = started
        let port = BridgeServer.portFromEnvironment()
        let server = BridgeServer(port: port, eventSource: mediaKeys) {
            monitor.currentStatus(
                port: port,
                uptime: Int(max(0, Date().timeIntervalSince(started))),
                mediaKeys: mediaKeys.mediaKeysActive
            )
        }
        self.server = server
        let updater = Updater()
        self.updater = updater
        statusItem = StatusItemController(monitor: monitor, audio: audio, mediaKeys: mediaKeys, updater: updater)
        updater.start()
        // The App init runs exactly once per process launch, so the server
        // is started exactly once here.
        server.start()
        // After the server: /events is what makes the media-key capture
        // worth having, and the `.auto` policy only claims once a consumer
        // has polled it.
        mediaKeys.start()
    }

    var body: some Scene {
        // The status item is plain AppKit (`StatusItemController`): SwiftUI's
        // `MenuBarExtra` label silently drops any `Image(nsImage:)`, which
        // rules out the battery dots. The only SwiftUI scene is an unused
        // Settings window (the app is LSUIElement; it has no main window).
        Settings { EmptyView() }
    }
}

// MARK: - Status item (AppKit)

/// Owns the `NSStatusItem` and the popover that hosts `SoundMenuView`.
/// Relabels the item whenever the battery, the connection or the chosen
/// `BatteryStyle` changes.
@MainActor
final class StatusItemController {

    private let item: NSStatusItem
    private let popover = NSPopover()
    private let monitor: BatteryMonitor
    private let audio: AudioOutputController
    private let mediaKeys: MediaKeyMonitor
    private let updater: Updater
    private var cancellables = Set<AnyCancellable>()

    init(monitor: BatteryMonitor, audio: AudioOutputController, mediaKeys: MediaKeyMonitor, updater: Updater) {
        self.monitor = monitor
        self.audio = audio
        self.mediaKeys = mediaKeys
        self.updater = updater
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        popover.behavior = .transient
        popover.animates = false
        monitor.$battery.combineLatest(monitor.$connected)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.relabel() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.relabel() }
            .store(in: &cancellables)
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in self.relabel() }
        }
        relabel()
    }

    private var appearanceObservation: NSKeyValueObservation?

    private var style: BatteryStyle {
        BatteryStyle(rawValue: UserDefaults.standard.string(forKey: BatteryStyle.key) ?? "") ?? .fallback
    }

    /// One composite image: the headphones glyph with the battery underneath
    /// (dots or a small percentage), so the item is no wider than the glyph.
    /// The glyph is drawn in the bar's current label colour — the image can't
    /// be a template (that would flatten the green dots) — and is redrawn
    /// when the bar's appearance changes.
    private func relabel() {
        guard let button = item.button else { return }
        button.attributedTitle = NSAttributedString(string: "")
        guard let battery = monitor.battery else {
            button.image = NSImage(
                systemSymbolName: monitor.connected ? "headphones" : "headphones.circle",
                accessibilityDescription: "Headset"
            )
            button.toolTip = nil
            return
        }
        var image: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(level: battery, style: style)
        }
        button.image = image
        button.toolTip = "\(monitor.deviceName ?? "Headset") — \(battery)%"
    }

    private var settingsWindow: NSWindow?

    /// Shows (or re-focuses) the Settings panel. The app is LSUIElement, so
    /// it has to activate itself for the window to come forward.
    func showSettings() {
        popover.performClose(nil)
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: SettingsView(updater: updater, mediaKeyStateText: mediaKeyStateText)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "HeadsetCompanion Settings"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Size the window to the SwiftUI content *before* centring: NSWindow
        // otherwise centres its placeholder frame and the panel lands off to
        // the side once the content lays out.
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentViewController = NSHostingController(
            rootView: SoundMenuView(
                audio: audio,
                monitor: monitor,
                mediaKeyStateText: mediaKeyStateText,
                updater: updater,
                openSettings: { [weak self] in self?.showSettings() }
            )
        )
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // Opening the menu must not focus anything: AppKit would otherwise
        // hand first responder to the first control (the mute button), which
        // then wears a focus ring and swallows the space bar.
        window?.initialFirstResponder = nil
        window?.makeFirstResponder(nil)
    }

    /// Who MediaRemote currently routes the media keys to: Sonora while the
    /// now-playing claim is held, otherwise whatever app holds it (typically
    /// the browser). `passive` never claims.
    private var mediaKeyStateText: String {
        if mediaKeys.policy == .passive { return "passive" }
        return mediaKeys.isActive ? "Sonora" : "browser"
    }
}

// MARK: - Menu bar battery style

/// How the menu bar shows the headset battery — chosen from the menu and
/// remembered in UserDefaults.
enum BatteryStyle: String, CaseIterable, Identifiable {
    case percent, dots
    static let key = "menuBarBatteryStyle"
    /// What a fresh install shows: the dots, which take the least width.
    static let fallback: BatteryStyle = .dots
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: return "Percent"
        case .dots: return "Dots"
        }
    }
}

// MARK: - Menu bar label

/// Draws the status item image: headphones glyph on top, battery below.
/// 18 pt wide, full menu bar height, rendered at 2x.
enum MenuBarLabel {
    static let width: CGFloat = 18
    static let height: CGFloat = 18
    static let dotCount = 5
    static let dotDiameter: CGFloat = 2
    static let dotGap: CGFloat = 1

    /// Dots lit for a level: one per 20 %, rounded up (30 % → 2, 90 % → 5).
    static func filledDots(level: Int) -> Int {
        let clamped = min(max(level, 0), 100)
        return min(dotCount, Int((Double(clamped) / 20).rounded(.up)))
    }

    static func image(level: Int, style: BatteryStyle) -> NSImage {
        let size = NSSize(width: width, height: height)
        let ink = NSColor.labelColor
        // `flipped: true` gives a top-left origin regardless of the context;
        // rasterised into a bitmap (the status bar needs real pixels) at 2x.
        let drawn = NSImage(size: size, flipped: true) { _ in
            draw(level: level, style: style, ink: ink)
            return true
        }
        let image = NSImage(size: size)
        for scale in [1, 2] as [CGFloat] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            drawn.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = false
        return image
    }

    /// Top-left origin. Glyph in the top 11 pt, battery in the bottom 5 pt.
    private static func draw(level: Int, style: BatteryStyle, ink: NSColor) {

        // Glyph: top 12 pt, tinted with the label colour.
        if let glyph = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: style == .percent ? 9.5 : 11, weight: .regular)) {
            let tinted = glyph.copy() as! NSImage
            tinted.lockFocus()
            ink.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let g = tinted.size
            tinted.draw(in: NSRect(x: (width - g.width) / 2, y: 0, width: g.width, height: g.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Battery: bottom 7 pt.
        switch style {
        case .dots:
            let lit = filledDots(level: level)
            let rowWidth = CGFloat(dotCount) * dotDiameter + CGFloat(dotCount - 1) * dotGap
            let x0 = (width - rowWidth) / 2
            for i in 0..<dotCount {
                let rect = NSRect(x: x0 + CGFloat(i) * (dotDiameter + dotGap), y: height - dotDiameter - 1,
                                  width: dotDiameter, height: dotDiameter)
                (i < lit ? NSColor.systemGreen : ink.withAlphaComponent(0.3)).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
        case .percent:
            let text = NSAttributedString(string: "\(level)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 5.5, weight: .semibold),
                .foregroundColor: ink,
            ])
            let t = text.size()
            // Centre under the glyph; the glyph is kept smaller in this
            // mode so the two don't touch.
            text.draw(in: NSRect(x: (width - t.width) / 2, y: height - t.height + 0.5,
                                 width: t.width, height: t.height))
        }
    }
}

// MARK: - Window content

/// The menu popover, laid out like Apple's Sound menu: title, system volume
/// slider, the list of output devices, then settings/quit.
struct SoundMenuView: View {

    @ObservedObject var audio: AudioOutputController
    @ObservedObject var monitor: BatteryMonitor
    let mediaKeyStateText: String
    @ObservedObject var updater: Updater
    /// Opens the Settings panel (owned by `StatusItemController`).
    let openSettings: () -> Void

    /// Devices don't all notify on volume changes (and nothing notifies when
    /// another app changes it), so the open menu also polls once a second.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            volumeSlider
                .padding(.horizontal, 12)

            Divider()
                .padding(.horizontal, 12)

            Text("Output")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(audio.devices) { device in
                    deviceRow(device)
                }
            }
            .padding(.horizontal, 6)

            Divider()
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 2) {
                MenuRowButton(action: openSoundSettings) {
                    Text("Sound Settings…")
                }
                MenuRowButton(action: openSettings) {
                    Text("Settings…")
                }
                MenuRowButton(action: { NSApplication.shared.terminate(nil) }) {
                    Text("Quit")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
        .frame(width: 280)
        .onReceive(tick) { _ in audio.refreshVolume() }
    }

    // MARK: - Volume

    private var volumeSlider: some View {
        HStack(spacing: 8) {
            Button(action: audio.toggleMute) {
                Image(systemName: AudioOutputFormatting.speakerIconName(
                    muted: audio.muted, volume: audio.volume
                ))
                .frame(width: 14)
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help(audio.muted ? "Unmute" : "Mute")

            Slider(
                value: Binding(get: { audio.volume }, set: { audio.setVolume($0) }),
                in: 0...1
            )
            .disabled(!audio.volumeSupported)

            Image(systemName: "speaker.wave.3.fill")
                .frame(width: 14)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Output list

    private func deviceRow(_ device: AudioOutputDevice) -> some View {
        let isDefault = device.id == audio.defaultDeviceID
        return MenuRowButton(highlighted: isDefault) {
            audio.selectDevice(device)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: AudioOutputFormatting.iconName(forTransportType: device.transportType))
                    .frame(width: 16)
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let percent = batteryPercent(device),
                   let label = AudioOutputFormatting.batteryLabel(percent) {
                    Label(label, systemImage: AudioOutputFormatting.batteryIconName(percent))
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(isDefault ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
            }
        }
    }

    /// Every Bluetooth row the system reports a level for gets a label. The
    /// bridge's own device uses the monitor's published value, which also
    /// covers the GATT source and the last-known fallback.
    private func batteryPercent(_ device: AudioOutputDevice) -> Int? {
        if isBridgeDevice(device) { return monitor.battery }
        return AudioOutputFormatting.batteryPercent(
            forDeviceName: device.name,
            transportType: device.transportType,
            readings: monitor.systemReadings
        )
    }

    private func isBridgeDevice(_ device: AudioOutputDevice) -> Bool {
        AudioOutputFormatting.matchesBridgeDevice(
            deviceName: device.name,
            transportType: device.transportType,
            bridgeDeviceName: monitor.deviceName,
            nameFilter: BatteryMonitor.effectiveNameFilter
        )
    }

    private func openSoundSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A full-width menu row that highlights on hover (and stays highlighted for
/// the current selection), the way AppKit menu items do.
struct MenuRowButton<Label: View>: View {

    var highlighted = false
    let action: () -> Void
    @ViewBuilder let label: Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: AnyShapeStyle {
        if hovering { return AnyShapeStyle(Color.primary.opacity(0.14)) }
        if highlighted { return AnyShapeStyle(Color.primary.opacity(0.08)) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - Settings panel

/// The Settings window: everything that isn't picking an output device, so
/// the menu itself stays a short list.
struct SettingsView: View {

    @ObservedObject var updater: Updater
    let mediaKeyStateText: String

    @AppStorage(BatteryStyle.key) private var batteryStyle = BatteryStyle.fallback
    @AppStorage(Updater.autoCheckKey) private var autoCheckUpdates = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Menu bar battery:", selection: $batteryStyle) {
                        ForEach(BatteryStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("How the menu bar shows the headset battery.")
                }

                Section {
                    Toggle("Check for updates daily", isOn: $autoCheckUpdates)
                        .help("Looks for a newer release once a day and installs it.")
                    HStack(spacing: 10) {
                        Button(updateButtonTitle, action: checkForUpdates)
                            .disabled(updateBusy)
                        if updateBusy { ProgressView().controlSize(.small) }
                        Text(updateStatusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Updates")
                }

                Section {
                    LabeledContent("Media keys go to:", value: mediaKeyStateText)
                        .help("Which app MediaRemote routes headset and F7–F9 taps to.")
                    LabeledContent("Version:", value: "v\(updater.currentVersion)")
                } header: {
                    Text("About")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Updates

    private var updateBusy: Bool {
        switch updater.state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private var updateButtonTitle: String {
        if case .available = updater.state { return "Install Update" }
        return "Check for Updates"
    }

    private var updateStatusText: String {
        switch updater.state {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date (v\(updater.currentVersion))"
        case .available(let r): return "v\(r.version) is available"
        case .downloading: return "Downloading…"
        case .installing: return "Installing — the app will relaunch"
        case .failed(let msg): return msg
        }
    }

    private func checkForUpdates() {
        switch updater.state {
        case .available(let r): Task { await updater.install(r) }
        case .checking, .downloading, .installing: break
        default: Task { await updater.check(install: false) }
        }
    }
}
