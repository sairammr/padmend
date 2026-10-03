import Foundation
import PadmendCore
import PadmendKit

/// Enough of the pad covered for the result to be worth saving. Below this a
/// map would mostly be condemning whatever the user happened to miss.
private let minimumCoverage = 0.75

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

    let capture = CalibrationCapture(grid: device.grid)
    let stream = MultitouchStream()
    do {
        try stream.start(device: device) { frame in capture.ingest(frame) }
    } catch {
        fail("\(error)")
    }

    let aborted = Flag()
    print(Terminal.hideCursor, terminator: "")

    let redraw = Timer(timeInterval: 0.08, repeats: true) { _ in
        let state = capture.snapshot()
        var screen = Terminal.home
        screen += "  calibrating \(device.grid.cols)x\(device.grid.rows) sensor"
        screen += "   \(Terminal.bar(state.progress))        \n\n"
        screen += Terminal.render(coverage: state.coverage, fingers: state.fingers)
        screen += "\n\n  \(Terminal.legend)\n"
        screen += "\n  Sweep the whole pad in slow overlapping strokes, "
        screen += "including the edges.\n"
        screen += "  Red means your finger was there and the pad said nothing.\n"
        screen += String(format: "  dropouts repaired: %-6d frames: %-8d\n",
                         state.repairedDropouts, state.frameCount)
        if state.progress >= minimumCoverage {
            screen += "\n  Enough of the pad is covered. "
            screen += "Press return to save, or keep sweeping.  "
        } else {
            screen += "\n  Keep sweeping. Return saves anyway, q then return aborts."
        }
        print(screen, terminator: "")
    }
    RunLoop.main.add(redraw, forMode: .common)

    // stdin is read on its own thread so the main run loop keeps servicing the
    // contact stream while we wait for the user to finish.
    let reader = Thread {
        let line = readLine(strippingNewline: true) ?? ""
        aborted.set(line.lowercased().hasPrefix("q"))
        CFRunLoopStop(CFRunLoopGetMain())
    }
    reader.start()

    CFRunLoopRun()

    redraw.invalidate()
    stream.stop()
    print(Terminal.showCursor, terminator: "")
    print("")

    if aborted.value {
        print("aborted; nothing saved")
        return
    }

    let map = capture.makeDeadMap()
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

    let foundNothing = map.condemnedColumns.isEmpty && map.condemnedRows.isEmpty
        && !map.health.contains(.dead) && !map.health.contains(.flaky)
    if foundNothing {
        print("""

                Nothing wrong was found. If the pad still misbehaves, sweep \
              more slowly next time — a fast stroke gives the sensor fewer \
              chances to fail, so a bad cell can look fine.
              """)
    }
    print("\n  Next: padmend run")
}

/// A boolean two threads can share.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }
}
