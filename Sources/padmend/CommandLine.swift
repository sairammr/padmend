import Foundation
import PadmendCore
import PadmendKit

let usage = """
padmend — make a trackpad with dead spots behave

usage: padmend <command>

  doctor      check permissions and what is set up
  selftest    check everything that can be checked without touching the pad
  devices     list the multitouch devices the system reports
  probe       print the raw contact stream, to see what the sensor reports
  calibrate   sweep the pad to find its dead and intermittent areas
  map         show the saved map
  run         take over the trackpad and compensate
  reset       discard the saved map

Compensation needs two permissions, both granted to whatever launched this:
Input Monitoring to read the sensor, Accessibility to replace its output.
While `run` is active, control-option-command-P turns it off.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("padmend: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    print(message)
}

// MARK: - doctor

func commandDoctor() {
    print("padmend\n")

    print("permissions")
    print("  input monitoring  \(Permissions.inputMonitoring.symbol)  (read the sensor)")
    print("  accessibility     \(Permissions.accessibility.symbol)  (replace its output)")

    print("\nhardware")
    do {
        let devices = try MultitouchStream.devices()
        if devices.isEmpty {
            print("  no multitouch devices reported")
        }
        for device in devices { print("  \(device.description)") }
        let chosen = try MultitouchStream.defaultDevice()
        print("  using: device \(chosen.index)")
    } catch {
        print("  \(error)")
    }

    print("\nmap")
    if let map = Store.loadDeadMap() {
        let dead = map.health.count { $0 == .dead }
        let flaky = map.health.count { $0 == .flaky }
        print("  \(Store.deadMapURL.path)")
        print("  \(dead) dead cells, \(flaky) intermittent cells")
        print("  condemned columns: \(describe(map.condemnedColumns))")
        print("  condemned rows:    \(describe(map.condemnedRows))")
        let mapper = PointerMapper(deadMap: map)
        print(String(format: "  compensation: %.2fx across, %.2fx up",
                     mapper.compensation.x, mapper.compensation.y))
    } else {
        print("  none saved — run `padmend calibrate`")
    }

    if Permissions.inputMonitoring != .granted {
        print("\nAsking for Input Monitoring now.")
        Permissions.requestInputMonitoring()
    }
    if Permissions.accessibility != .granted {
        print("Asking for Accessibility now.")
        Permissions.requestAccessibility()
    }
}

func describe(_ indices: Set<Int>) -> String {
    indices.isEmpty ? "none" : indices.sorted().map(String.init).joined(separator: ", ")
}

// MARK: - devices

func commandDevices() {
    do {
        let devices = try MultitouchStream.devices()
        guard !devices.isEmpty else { fail("no multitouch devices") }
        for device in devices { print(device.description) }
    } catch {
        fail("\(error)")
    }
}

// MARK: - probe

func commandProbe() {
    setvbuf(stdout, nil, _IONBF, 0)
    let stream = MultitouchStream()
    do {
        let device = try MultitouchStream.defaultDevice()
        print(device.description)
        print("touch the pad; control-c to stop")
        print("(nothing printing? Input Monitoring is \(Permissions.inputMonitoring.symbol))")

        try stream.start(device: device) { frame in
            guard !frame.samples.isEmpty else { return }
            var line = String(format: "%.3f  n=%d", frame.timestamp,
                              frame.samples.count)
            for sample in frame.samples {
                line += String(format: "  [id=%d st=%d x=%.4f y=%.4f sz=%.2f]",
                               sample.hardwareID, sample.state.rawValue,
                               sample.position.x, sample.position.y, sample.size)
            }
            print(line)
        }
    } catch {
        fail("\(error)")
    }
    RunLoop.main.run()
}

// MARK: - map

func commandMap() {
    guard let map = Store.loadDeadMap() else {
        fail("no saved map — run `padmend calibrate`")
    }
    let mapper = PointerMapper(deadMap: map)
    print("saved \(map.createdAt.formatted())   sensor \(map.grid.cols)x\(map.grid.rows)")
    print("")
    print(Terminal.render(deadMap: map))
    print("")
    print(Terminal.legend)
    print("")
    print("condemned columns: \(describe(map.condemnedColumns))")
    print("condemned rows:    \(describe(map.condemnedRows))")
    print(String(format: "compensation:      %.2fx across, %.2fx up",
                 mapper.compensation.x, mapper.compensation.y))
}

// MARK: - reset

func commandReset() {
    do {
        try Store.removeDeadMap()
        print("map discarded")
    } catch {
        fail("could not remove \(Store.deadMapURL.path): \(error)")
    }
}
