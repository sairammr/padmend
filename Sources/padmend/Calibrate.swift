import Foundation
import PadmendCore
import PadmendKit

/// Interactive calibration.
///
/// The user sweeps the pad while the evidence builds up on screen. Showing the
/// map as it fills is not decoration: the user is the measuring instrument
/// here, and they can only tell whether they have swept enough — or whether a
/// red stripe is real — by watching it appear.
func commandCalibrate() {
    guard Permissions.inputMonitoring == .granted else {
        Permissions.requestInputMonitoring()
        fail("""
             Input Monitoring is not granted, so the sensor cannot be read.
             Grant it in System Settings › Privacy & Security › Input \
             Monitoring, then run this again.
             """)
    }

    let device: TrackpadDevice
    do {
        device = try MultitouchStream.defaultDevice()
    } catch {
        fail("\(error)")
    }

    let calibrator = Calibrator(grid: device.grid)
    let engine = Engine(device: device,
                        deadMap: .empty(grid: device.grid),
                        settings: Store.loadSettings(),
                        trackerConfig: .calibration)

    let state = CalibrationState()
    engine.onFrame = { frame, output in
        calibrator.ingest(frame: frame, output: output)
        state.setFingers(output.fingers.map(\.position))
    }

    do {
        try engine.start(mode: .observe)
    } catch {
        fail("\(error)")
    }

    print(Terminal.hideCursor, terminator: "")
    let redraw = Timer(timeInterval: 0.08, repeats: true) { _ in
        var screen = Terminal.home
        screen += "  calibrating \(device.grid.cols)x\(device.grid.rows) sensor"
        screen += "   \(Terminal.bar(calibrator.progress))        \n\n"
        screen += Terminal.render(coverage: calibrator.coverage,
                                  fingers: state.fingers)
        screen += "\n\n  \(Terminal.legend)\n"
        screen += "\n  Sweep the whole pad in slow overlapping strokes, "
        screen += "including the edges.\n"
        screen += "  Red means your finger was there and the pad said nothing.\n"
        screen += String(format: "  dropouts repaired: %-6d frames: %-8d\n",
                         calibrator.repairedDropouts, calibrator.frameCount)
        screen += "\n  Press return to save, or q then return to abort.   "
        print(screen, terminator: "")
    }
    RunLoop.main.add(redraw, forMode: .common)

    // stdin is read on its own thread so the contact stream keeps being
    // serviced by the main run loop while we wait.
    let reader = Thread {
        let line = readLine(strippingNewline: true) ?? ""
        state.setAbort(line.lowercased().hasPrefix("q"))
        CFRunLoopStop(CFRunLoopGetMain())
    }
    reader.start()

    CFRunLoopRun()

    redraw.invalidate()
    engine.stop()
    print(Terminal.showCursor, terminator: "")
    print("")

    if state.aborted {
        print("aborted; nothing saved")
        return
    }

    let map = calibrator.makeDeadMap()
    guard map.isCalibrated else {
        fail("no evidence gathered — was the pad touched?")
    }

    do {
        try Store.save(map)
    } catch {
        fail("could not save to \(Store.deadMapURL.path): \(error)")
    }

    let mapper = PointerMapper(deadMap: map)
    print(Terminal.render(deadMap: map))
    print("")
    print("  \(Terminal.legend)")
    print("")
    print("  saved to \(Store.deadMapURL.path)")
    print("  condemned columns: \(describe(map.condemnedColumns))")
    print("  condemned rows:    \(describe(map.condemnedRows))")
    print(String(format: "  compensation:      %.2fx across, %.2fx up",
                 mapper.compensation.x, mapper.compensation.y))
    if map.condemnedColumns.isEmpty && map.condemnedRows.isEmpty
        && !map.health.contains(.dead) && !map.health.contains(.flaky) {
        print("\n  Nothing wrong was found. If the pad still misbehaves, "
              + "sweep more slowly and cover the edges.")
    }
    print("\n  Next: padmend run")
}

/// Shared between the contact-stream thread and the redraw timer.
final class CalibrationState {
    private let lock = NSLock()
    private var _fingers: [Point] = []
    private var _aborted = false

    var fingers: [Point] {
        lock.lock(); defer { lock.unlock() }
        return _fingers
    }

    var aborted: Bool {
        lock.lock(); defer { lock.unlock() }
        return _aborted
    }

    func setFingers(_ fingers: [Point]) {
        lock.lock()
        _fingers = fingers
        lock.unlock()
    }

    func setAbort(_ aborted: Bool) {
        lock.lock()
        _aborted = aborted
        lock.unlock()
    }
}
