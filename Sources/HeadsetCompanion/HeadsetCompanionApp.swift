import AppKit
import Combine
import ServiceManagement
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
    /// Owned here, not by the status item: the `⌘,` scene shows the same
    /// switch, and two `LoginItem`s would each hold their own idea of a
    /// state that actually lives in System Settings.
    private let loginItem = LoginItem()

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
        statusItem = StatusItemController(
            monitor: monitor, audio: audio, mediaKeys: mediaKeys, updater: updater,
            loginItem: loginItem
        )
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
        // rules out the battery dots. `Settings` is the only scene this app
        // declares (it is LSUIElement and has no main window) — and macOS
        // wires that scene to the Settings menu item and `⌘,` whether or not
        // it holds anything, so it has to hold the real panel. An
        // `EmptyView()` here is a blank window titled "HeadsetCompanion
        // Settings" that the user can open by accident and learn nothing
        // from.
        Settings {
            SettingsView(
                updater: updater,
                loginItem: loginItem,
                mediaKeyStateText: mediaKeys.stateText
            )
        }
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
    private let loginItem: LoginItem
    private var cancellables = Set<AnyCancellable>()

    init(
        monitor: BatteryMonitor, audio: AudioOutputController, mediaKeys: MediaKeyMonitor,
        updater: Updater, loginItem: LoginItem
    ) {
        self.monitor = monitor
        self.audio = audio
        self.mediaKeys = mediaKeys
        self.updater = updater
        self.loginItem = loginItem
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
        // The glyph follows the default output, so the item has to relabel on
        // a device switch too. Taken off the published properties rather than
        // `onDefaultDeviceChange`, which already belongs to the monitor's
        // `refreshTarget()` and must not be overwritten.
        audio.$defaultDeviceID.combineLatest(audio.$devices)
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

    /// Everything the button's image and tooltip are derived from, as of the
    /// last time `relabel()` actually drew.
    private struct RenderedLabel: Equatable {
        let plan: MenuBarLabelPlan
        let battery: Int?
        let style: BatteryStyle
        let appearance: NSAppearance.Name?
        let outputName: String?
        let headsetName: String?
    }

    private var lastRendered: RenderedLabel?

    private var style: BatteryStyle {
        BatteryStyle(rawValue: UserDefaults.standard.string(forKey: BatteryStyle.key) ?? "") ?? .fallback
    }

    /// The device sound is currently going to — the same "is default" notion
    /// the menu highlights its row with.
    private var defaultOutputDevice: AudioOutputDevice? {
        audio.devices.first { $0.id == audio.defaultDeviceID }
    }

    /// One composite image: the output's glyph with the battery underneath
    /// (dots or a small percentage) when that output has one, so the item is
    /// no wider than the glyph. The glyph is drawn in the bar's current label
    /// colour — the image can't be a template (that would flatten the green
    /// dots) — and is redrawn when the bar's appearance changes.
    private func relabel() {
        guard let button = item.button else { return }
        let device = defaultOutputDevice
        let plan = MenuBarLabelPlan.forOutput(
            transportType: device?.transportType,
            deviceName: device?.name,
            battery: monitor.battery,
            connected: monitor.connected
        )
        // Nothing below this moved, so the button already shows the right
        // thing — and writing to it anyway is worse than wasted work. Setting
        // `image` makes AppKit redraw the item's replicant on a second menu
        // bar; that redraw calls `setAppearance:` on the snapshot view, which
        // fires the `effectiveAppearance` KVO above, which calls back in here.
        // Unguarded that is an unbounded loop, and it pins a core for as long
        // as two displays are attached. Keyed on the appearance *name*, which
        // is what separates aqua from darkAqua: a repaint the name cannot see
        // is a cosmetic miss, a permanently spinning main thread is not.
        let rendered = RenderedLabel(
            plan: plan,
            battery: monitor.battery,
            style: style,
            appearance: button.effectiveAppearance.name,
            outputName: device?.name,
            headsetName: monitor.deviceName
        )
        guard rendered != lastRendered else { return }
        lastRendered = rendered
        button.attributedTitle = NSAttributedString(string: "")
        guard device != nil || plan.showsBattery else {
            // Nothing to say about the output yet: the plain system symbol,
            // sized by the status bar itself, exactly as before.
            button.image = NSImage(
                systemSymbolName: plan.symbolName, accessibilityDescription: "Headset"
            )
            button.toolTip = nil
            return
        }
        var image: NSImage?
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image = MenuBarLabel.image(
                level: plan.showsBattery ? monitor.battery : nil,
                style: style,
                symbolName: plan.symbolName
            )
        }
        button.image = image
        if plan.showsBattery, let battery = monitor.battery {
            button.toolTip = "\(monitor.deviceName ?? device?.name ?? "Headset") — \(battery)%"
        } else {
            button.toolTip = device?.name
        }
    }

    private var settingsWindow: NSWindow?

    /// Shows (or re-focuses) the Settings panel. The app is LSUIElement, so
    /// it has to activate itself for the window to come forward.
    func showSettings() {
        popover.performClose(nil)
        // The `Settings` scene is the same panel `⌘,` opens, so route here
        // too and the two cannot end up as two windows of the same thing.
        // AppKit dispatches this action for the Settings menu item; it
        // reports whether anything handled it, and the hand-built window
        // below stays as the answer for when nothing does.
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: SettingsView(
                updater: updater, loginItem: loginItem, mediaKeyStateText: mediaKeyStateText
            )
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
    private var mediaKeyStateText: String { mediaKeys.stateText }
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

/// What the status item should draw right now: which SF Symbol, and whether
/// the battery row belongs under it.
///
/// The menu bar has to say *where the sound is going*, so the glyph follows
/// the default output device rather than the headset. Only a Bluetooth output
/// can report a battery, so every other device gets its own icon and no
/// battery row — drawing dots for the built-in speakers would be inventing a
/// reading that doesn't exist.
struct MenuBarLabelPlan: Equatable {
    let symbolName: String
    let showsBattery: Bool

    /// - Parameters:
    ///   - transportType: `kAudioDevicePropertyTransportType` of the current
    ///     default output, `nil` when no default device is known yet.
    ///   - deviceName: the default output's CoreAudio name, used only to pick
    ///     a nicer glyph for AirPods — nothing else keys off the brand.
    ///   - battery: the monitor's level, `nil` before the first reading.
    ///   - connected: whether the headset link is up (only used by the
    ///     no-device-known fallback, which predates the device lookup).
    static func forOutput(
        transportType: UInt32?,
        deviceName: String? = nil,
        battery: Int?,
        connected: Bool
    ) -> MenuBarLabelPlan {
        guard let transportType else {
            // Nothing known about the output: the long-standing fallback —
            // headphones, circled while the link is down.
            if battery != nil { return MenuBarLabelPlan(symbolName: "headphones", showsBattery: true) }
            return MenuBarLabelPlan(
                symbolName: connected ? "headphones" : "headphones.circle", showsBattery: false
            )
        }
        // The device rows in the menu already map transport types to symbols;
        // reuse that mapping so the bar and the list can't disagree.
        let icon = AudioOutputFormatting.iconName(forTransportType: transportType)
        guard AudioOutputFormatting.isBluetooth(transportType: transportType) else {
            return MenuBarLabelPlan(symbolName: icon, showsBattery: false)
        }
        return MenuBarLabelPlan(
            symbolName: airPodsSymbolName(deviceName) ?? icon, showsBattery: battery != nil
        )
    }

    /// Apple ships a glyph per AirPods model, and a pair of AirPods Max in the
    /// bar reading "headphones" looks like a generic placeholder. This is the
    /// only place the app looks at a brand: the choice of symbol. Nothing —
    /// device selection, battery reading, matching — keys off it.
    ///
    /// `nil` for every other device, so it falls through to the transport
    /// mapping. Matched on the name as people actually have it: any case, and
    /// any run of whitespace (non-breaking spaces included, which is what a
    /// renamed "AirPods Pro" often carries).
    static func airPodsSymbolName(_ deviceName: String?) -> String? {
        guard let deviceName else { return nil }
        let name = deviceName
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if name.contains("airpods max") { return "airpods.max" }
        if name.contains("airpods pro") { return "airpods.pro" }
        if name.contains("airpods") { return "airpods" }
        return nil
    }
}

/// Draws the status item image: output glyph on top, battery below when the
/// device has one. 18 pt wide, full menu bar height, rendered at 2x.
enum MenuBarLabel {
    static let width: CGFloat = 18
    static let height: CGFloat = 18
    static let dotCount = 5
    static let dotDiameter: CGFloat = 2
    static let dotGap: CGFloat = 1
    /// A glyph with nothing under it can use the whole height, so it is drawn
    /// bigger than the 11 pt the composite squeezes into its top half.
    static let soloPointSize: CGFloat = 12.5

    /// Dots lit for a level: one per 20 %, rounded up (30 % → 2, 90 % → 5).
    static func filledDots(level: Int) -> Int {
        let clamped = min(max(level, 0), 100)
        return min(dotCount, Int((Double(clamped) / 20).rounded(.up)))
    }

    /// The first of `preferred`, then `fallback`, that this macOS actually
    /// has — `NSImage(systemSymbolName:)` returns nil for a symbol the system
    /// doesn't know (the AirPods glyphs aren't guaranteed on every 13.x), and
    /// a missing symbol would otherwise leave the item blank.
    static func availableSymbolName(_ preferred: String, fallback: String = "headphones") -> String? {
        for name in [preferred, fallback]
        where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return nil
    }

    /// `level` is `nil` for an output that reports no battery: then the glyph
    /// alone is drawn, centred, with no room reserved underneath.
    static func image(level: Int?, style: BatteryStyle, symbolName: String = "headphones") -> NSImage {
        let pointSize = level == nil ? soloPointSize : (style == .percent ? 9.5 : 11)
        let glyph = availableSymbolName(symbolName)
            .flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        // Wider glyphs than the headphones one (a laptop, a display) would be
        // clipped by a fixed 18 pt box, so the box grows to fit them.
        let boxWidth = max(width, (glyph?.size.width ?? 0).rounded(.up))
        let size = NSSize(width: boxWidth, height: height)
        let ink = NSColor.labelColor
        // `flipped: true` gives a top-left origin regardless of the context;
        // rasterised into a bitmap (the status bar needs real pixels) at 2x.
        let drawn = NSImage(size: size, flipped: true) { _ in
            draw(level: level, style: style, ink: ink, glyph: glyph, boxWidth: boxWidth)
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

    /// Top-left origin. With a battery: glyph in the top 11 pt, battery in the
    /// bottom 5 pt. Without one: the glyph centred in the full height.
    private static func draw(
        level: Int?, style: BatteryStyle, ink: NSColor, glyph: NSImage?, boxWidth: CGFloat
    ) {

        // Glyph: top 12 pt, tinted with the label colour.
        if let glyph {
            let tinted = glyph.copy() as! NSImage
            tinted.lockFocus()
            ink.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let g = tinted.size
            let y = level == nil ? (height - g.height) / 2 : 0
            tinted.draw(in: NSRect(x: (boxWidth - g.width) / 2, y: y, width: g.width, height: g.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Battery: bottom 7 pt.
        guard let level else { return }
        switch style {
        case .dots:
            let lit = filledDots(level: level)
            let rowWidth = CGFloat(dotCount) * dotDiameter + CGFloat(dotCount - 1) * dotGap
            let x0 = (boxWidth - rowWidth) / 2
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
            text.draw(in: NSRect(x: (boxWidth - t.width) / 2, y: height - t.height + 0.5,
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
    @ObservedObject var loginItem: LoginItem
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

                    Toggle("Start at login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    ))
                    .help("Registers HeadsetCompanion with macOS as a login item.")
                    if let message = loginItem.message {
                        HStack(spacing: 8) {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if loginItem.needsApproval {
                                Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                                    .buttonStyle(.link)
                            }
                        }
                    }
                } header: {
                    Text("General")
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
        // The user can flip the login item in System Settings while this
        // window is closed, so ask macOS again every time it opens.
        .onAppear { loginItem.refresh() }
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
