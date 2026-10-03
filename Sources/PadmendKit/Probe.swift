import CMultitouch
import Foundation

/// Phase 0: prove the private multitouch stream opens on this machine and that
/// the 96-byte touch struct still decodes to sane values.
public func probeMain() {
    setvbuf(stdout, nil, _IONBF, 0)
    guard pm_available() else {
        let reason = pm_unavailable_reason().map { String(cString: $0) } ?? "unknown"
        FileHandle.standardError.write(Data("multitouch unavailable: \(reason)\n".utf8))
        exit(1)
    }

    print("MTTouch struct size: \(MemoryLayout<PMTouch>.size) bytes (expected 96)")

    let count = Int(pm_device_count())
    print("multitouch devices: \(count)")
    for index in 0..<count {
        var info = PMDeviceInfo()
        guard pm_device_info(Int32(index), &info) else { continue }
        let mmW = Double(info.surfaceWidth) / 100
        let mmH = Double(info.surfaceHeight) / 100
        print(String(format: "  [%d] family=%d surface=%.1fx%.1fmm sensor=%dx%d builtIn=%@ opaque=%@",
                     index, info.familyID, mmW, mmH, info.sensorCols, info.sensorRows,
                     info.builtIn ? "yes" : "no", info.opaque ? "yes" : "no"))
    }

    let chosen = Int(pm_default_device_index())
    guard chosen >= 0 else {
        FileHandle.standardError.write(Data("no usable trackpad found\n".utf8))
        exit(1)
    }
    print("chosen device: \(chosen)")

    guard pm_start(Int32(chosen), { touches, count, timestamp, frame, _ in
        guard count > 0, let touches else { return }
        var line = String(format: "f=%-7d t=%.3f n=%d", frame, timestamp, count)
        for i in 0..<Int(count) {
            let t = touches[i]
            line += String(format: "  [id=%d st=%d x=%.4f y=%.4f vx=%+.3f vy=%+.3f sz=%.2f]",
                           t.identifier, t.state,
                           t.normalized.position.x, t.normalized.position.y,
                           t.normalized.velocity.x, t.normalized.velocity.y,
                           t.size)
        }
        print(line)
    }, nil) else {
        FileHandle.standardError.write(Data("failed to start device\n".utf8))
        exit(1)
    }

    print("streaming — touch the trackpad; ctrl-c to stop")
    print("(if nothing prints, grant Input Monitoring to this terminal)")
    RunLoop.main.run()
}
