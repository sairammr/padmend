import AppKit
import Foundation
import PadmendCore

/// The menu bar application.
///
/// Compensation has to run all the time to be worth having, and a window is
/// the wrong shape for something that runs all the time. So the whole
/// interface is a status item: what state it is in, a switch, and a way to
/// recalibrate when the damage changes — which with a failing trackpad it does.
@MainActor
public final class MenuBarApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var engine: Engine?
    private var device: TrackpadDevice?
    private var deadMap: DeadMap?
    private var settings = Settings.default
    private var calibrationWindow: CalibrationWindowController?
    private var mapWindow: NSWindowController?
    private var startupError: String?

    private let enableItem = NSMenuItem(title: "Compensation",
                                        action: #selector(toggleEnabled),
                                        keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings = Store.loadSettings()
        buildStatusItem()

        do {
            let device = try MultitouchStream.defaultDevice()
            self.device = device
            self.deadMap = Store.loadDeadMap() ?? .empty(grid: device.grid)
        } catch {
            startupError = "\(error)"
        }

        if missingPermissions().isEmpty {
            if settings.enabledAtLaunch { startEngine() }
        } else {
            promptForPermissions()
        }
        refresh()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.and.hand.point.up.left",
            accessibilityDescription: "padmend")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        enableItem.target = self
        menu.addItem(enableItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Calibrate…", action: #selector(openCalibration),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Map…", action: #selector(openMap),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Settings Folder",
                     action: #selector(openSettingsFolder),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit padmend", action: #selector(quit),
                     keyEquivalent: "q").target = self

        item.menu = menu
        statusItem = item
    }

    private func refresh() {
        if let startupError {
            statusLine.title = startupError
            enableItem.isEnabled = false
            return
        }

        let missing = missingPermissions()
        if !missing.isEmpty {
            statusLine.title = "Needs \(missing.joined(separator: " and "))"
            enableItem.isEnabled = false
            statusItem?.button?.appearsDisabled = true
            return
        }

        enableItem.isEnabled = true
        let running = engine?.isSuppressing ?? false
        enableItem.state = running ? .on : .off
        statusItem?.button?.appearsDisabled = !running

        guard let map = deadMap else { return }
        if !map.isCalibrated {
            statusLine.title = running
                ? "Repairing dropouts — not calibrated yet"
                : "Off — not calibrated yet"
            return
        }

        let mapper = PointerMapper(deadMap: map, config: settings.pointer)
        let dead = map.condemnedColumns.count + map.condemnedRows.count
        let traces = dead == 1 ? "1 bad trace" : "\(dead) bad traces"
        statusLine.title = running
            ? String(format: "Compensating %.2fx — %@", mapper.compensation.x, traces)
            : "Off — \(traces) mapped"
    }

    // MARK: - Permissions

    private func missingPermissions() -> [String] {
        var missing: [String] = []
        if Permissions.inputMonitoring != .granted { missing.append("Input Monitoring") }
        if Permissions.accessibility != .granted { missing.append("Accessibility") }
        return missing
    }

    private func promptForPermissions() {
        let missing = missingPermissions()
        guard !missing.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "padmend needs permission"
        alert.informativeText = """
            Reading the trackpad sensor needs Input Monitoring. Replacing what \
            the trackpad sends needs Accessibility.

            Still needed: \(missing.joined(separator: ", ")).

            macOS grants these per application, so padmend has to be approved \
            even if your terminal already was.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            if Permissions.inputMonitoring != .granted {
                Permissions.requestInputMonitoring()
            }
            if Permissions.accessibility != .granted {
                Permissions.requestAccessibility()
            }
        }

        // The permission is granted outside this process, so the only way to
        // notice is to look again.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.missingPermissions().isEmpty else { return }
            timer.invalidate()
            if self.settings.enabledAtLaunch { self.startEngine() }
            self.refresh()
        }
    }

    // MARK: - Engine

    private func startEngine() {
        guard let device, let deadMap, engine == nil else { return }

        let engine = Engine(device: device, deadMap: deadMap, settings: settings)
        engine.onNotice = { message in
            NSLog("padmend: %@", message)
        }
        engine.onPanic = { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        do {
            try engine.start(mode: .takeover)
            self.engine = engine
        } catch {
            startupError = "\(error)"
        }
        refresh()
    }

    @objc private func toggleEnabled() {
        if engine == nil {
            startEngine()
        } else {
            engine?.setEnabled(!(engine?.isSuppressing ?? false))
        }
        settings.enabledAtLaunch = engine?.isSuppressing ?? false
        try? Store.save(settings)
        refresh()
    }

    // MARK: - Windows

    @objc private func openCalibration() {
        guard let device else { return }

        // Compensation is paused while calibrating: the sweep has to measure
        // the pad as it is, not as the repairs make it look.
        let wasRunning = engine?.isSuppressing ?? false
        engine?.setEnabled(false)

        let controller = CalibrationWindowController(device: device) { [weak self] map in
            guard let self else { return }
            if let map {
                self.deadMap = map
                try? Store.save(map)
                self.engine?.update(deadMap: map)
            }
            if wasRunning { self.engine?.setEnabled(true) }
            self.calibrationWindow = nil
            self.refresh()
        }
        calibrationWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    @objc private func openMap() {
        guard let deadMap else { return }

        let padView = PadView()
        padView.source = .map(deadMap)
        padView.translatesAutoresizingMaskIntoConstraints = false
        padView.heightAnchor.constraint(equalToConstant: 300).isActive = true

        let mapper = PointerMapper(deadMap: deadMap, config: settings.pointer)
        let summary = deadMap.isCalibrated
            ? String(format: """
                     Condemned columns: %@
                     Condemned rows: %@
                     Compensation: %.2fx across, %.2fx up
                     """,
                     describe(deadMap.condemnedColumns),
                     describe(deadMap.condemnedRows),
                     mapper.compensation.x, mapper.compensation.y)
            : "Not calibrated yet."

        let label = NSTextField(labelWithString: summary)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [padView, LegendView(includeFinger: false), label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Trackpad Map"
        window.contentView = stack
        window.center()

        let controller = NSWindowController(window: window)
        mapWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsFolder() {
        try? FileManager.default.createDirectory(at: Store.directory,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.open(Store.directory)
    }

    @objc private func quit() {
        engine?.stop()
        NSApp.terminate(nil)
    }

    private func describe(_ indices: Set<Int>) -> String {
        indices.isEmpty ? "none"
            : indices.sorted().map(String.init).joined(separator: ", ")
    }
}

/// Runs the menu bar application. Returns only when the user quits.
@MainActor
public func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    let delegate = MenuBarApp()
    app.delegate = delegate
    app.run()
    exit(0)
}
