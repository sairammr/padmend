import Foundation
import PadmendCore
import PadmendKit

/// Takeover mode.
func commandRun() {
    guard Permissions.inputMonitoring == .granted else {
        Permissions.requestInputMonitoring()
        fail("Input Monitoring is not granted; the sensor cannot be read.")
    }
    guard Permissions.accessibility == .granted else {
        Permissions.requestAccessibility()
        fail("""
             Accessibility is not granted, so the trackpad's own output cannot \
             be replaced. Grant it in System Settings › Privacy & Security › \
             Accessibility, then run this again.
             """)
    }

    let device: TrackpadDevice
    do {
        device = try MultitouchStream.defaultDevice()
    } catch {
        fail("\(error)")
    }

    let map = Store.loadDeadMap() ?? .empty(grid: device.grid)
    if !map.isCalibrated {
        note("no map saved, so there is nothing to compensate for yet.")
        note("dropout repair still applies. run `padmend calibrate` for the rest.\n")
    }

    let settings = Store.loadSettings()
    let engine = Engine(device: device, deadMap: map, settings: settings)
    engine.onNotice = { note("padmend: \($0)") }

    do {
        try engine.start(mode: .takeover)
    } catch {
        fail("\(error)")
    }

    let mapper = PointerMapper(deadMap: map, config: settings.pointer)
    print("padmend is driving the trackpad.")
    print("  device:       \(device.description)")
    print("  condemned:    columns \(describe(map.condemnedColumns)), "
          + "rows \(describe(map.condemnedRows))")
    print(String(format: "  compensation: %.2fx across, %.2fx up",
                 mapper.compensation.x, mapper.compensation.y))
    print("")
    print("  control-option-command-P  turn compensation off")
    print("  control-c                 quit and restore the trackpad")

    // The tap dies with the process, so a crash already restores the pad. This
    // is for the ordinary case, where leaving suppression on for the moment it
    // takes to exit would swallow the user's next gesture.
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber,
                                                     queue: .main)
        source.setEventHandler {
            engine.stop()
            print("\npadmend: stopped, trackpad restored")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    RunLoop.main.run()
}

/// Held so the signal sources are not deallocated the moment they are set up.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
