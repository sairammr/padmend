import CoreGraphics
import Foundation
import PadmendCore
import PadmendKit

/// Checks the half of the pipeline that does not need a finger: that synthetic
/// input can actually be posted, and that the event tap can be created and
/// torn down cleanly.
///
/// The pointer is moved and put back. If this leaves it somewhere unexpected,
/// that is itself the finding.
func commandSelfTest() {
    var failures = 0

    func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        if passed {
            print("  \u{1B}[32m✓\u{1B}[0m \(name)")
        } else {
            failures += 1
            print("  \u{1B}[31m✗\u{1B}[0m \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    print("padmend self-test\n")
    print("permissions")
    check("input monitoring", Permissions.inputMonitoring == .granted)
    check("accessibility", Permissions.accessibility == .granted)

    print("\nsensor")
    do {
        let device = try MultitouchStream.defaultDevice()
        check("trackpad found", true)
        check("sensor grid is plausible",
              device.grid.cols > 4 && device.grid.rows > 4,
              "got \(device.grid.cols)x\(device.grid.rows)")
        check("surface size is plausible",
              device.grid.widthMM > 20 && device.grid.heightMM > 20,
              String(format: "got %.1f x %.1f mm",
                     device.grid.widthMM, device.grid.heightMM))

        let stream = MultitouchStream()
        try stream.start(device: device) { _ in }
        check("contact stream opens", stream.isRunning)
        stream.stop()
    } catch {
        check("trackpad found", false, "\(error)")
    }

    print("\nposting input")
    let poster = EventPoster()
    let origin = poster.currentLocation()
    poster.moveCursor(dx: 37, dy: 23)
    usleep(60_000)
    let moved = poster.currentLocation()
    let dx = moved.x - origin.x
    let dy = moved.y - origin.y
    check("cursor responds to posted movement",
          abs(dx - 37) < 2 && abs(dy - 23) < 2,
          String(format: "asked for +37,+23 and got %+.0f,%+.0f", dx, dy))

    poster.moveCursor(dx: -Int(dx.rounded()), dy: -Int(dy.rounded()))
    usleep(60_000)
    let restored = poster.currentLocation()
    check("cursor was put back",
          abs(restored.x - origin.x) < 2 && abs(restored.y - origin.y) < 2,
          String(format: "off by %+.0f,%+.0f",
                 restored.x - origin.x, restored.y - origin.y))

    print("\nevent tap")
    let tap = EventTap()
    do {
        try tap.start()
        check("tap can be created", true)
        tap.setSuppressing(true)
        check("suppression can be turned on", tap.isSuppressing)
        tap.setSuppressing(false)
        check("suppression can be turned off", !tap.isSuppressing)
        tap.stop()
        check("tap tears down", true)
    } catch {
        check("tap can be created", false, "\(error)")
    }

    print("\nstored state")
    if let map = Store.loadDeadMap() {
        check("saved map loads", true)
        check("saved map matches this sensor",
              (try? MultitouchStream.defaultDevice().grid) == map.grid,
              "the map was made on a different pad; recalibrate")
    } else {
        print("  – no saved map yet (run `padmend calibrate`)")
    }

    print("")
    if failures == 0 {
        print("\u{1B}[32meverything that can be checked without a finger "
              + "on the pad works\u{1B}[0m")
        print("next: padmend calibrate")
    } else {
        print("\u{1B}[31m\(failures) check(s) failed\u{1B}[0m")
        exit(1)
    }
}
