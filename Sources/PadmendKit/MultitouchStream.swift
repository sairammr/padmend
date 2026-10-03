import CMultitouch
import Foundation
import PadmendCore

public struct TrackpadDevice: Sendable {
    public let index: Int
    public let familyID: Int32
    public let grid: SensorGrid
    public let isBuiltIn: Bool

    public var description: String {
        String(format: "device %d  family %d  %.1f x %.1f mm  sensor %dx%d  %@",
               index, familyID, grid.widthMM, grid.heightMM,
               grid.cols, grid.rows, isBuiltIn ? "built-in" : "external")
    }
}

public enum MultitouchError: Error, CustomStringConvertible {
    case unavailable(String)
    case noDevice
    case startFailed(Int)

    public var description: String {
        switch self {
        case .unavailable(let reason):
            return "MultitouchSupport is unavailable: \(reason)"
        case .noDevice:
            return "no trackpad found"
        case .startFailed(let index):
            return "could not start device \(index)"
        }
    }
}

/// Delivers the raw contact stream as `TouchFrame` values.
///
/// Frames arrive on MultitouchSupport's own thread. They are forwarded
/// straight through rather than hopped onto a queue: the pointer is being
/// driven from them, and a frame that arrives late is worse than a frame
/// handled on an unfamiliar thread. Everything downstream is owned by this
/// object alone, so there is nothing to contend over.
public final class MultitouchStream {
    public private(set) var device: TrackpadDevice?
    private var handler: (@Sendable (TouchFrame) -> Void)?

    /// The callback carries no context pointer, so the active stream is held
    /// here. One trackpad is the whole product.
    nonisolated(unsafe) private static weak var active: MultitouchStream?

    public init() {}

    public static func devices() throws -> [TrackpadDevice] {
        guard pm_available() else {
            throw MultitouchError.unavailable(reasonText())
        }
        return (0..<Int(pm_device_count())).compactMap { index in
            var info = PMDeviceInfo()
            guard pm_device_info(Int32(index), &info) else { return nil }
            return TrackpadDevice(
                index: index,
                familyID: info.familyID,
                grid: grid(from: info),
                isBuiltIn: info.builtIn)
        }
    }

    public static func defaultDevice() throws -> TrackpadDevice {
        guard pm_available() else {
            throw MultitouchError.unavailable(reasonText())
        }
        let index = Int(pm_default_device_index())
        guard index >= 0 else { throw MultitouchError.noDevice }
        var info = PMDeviceInfo()
        guard pm_device_info(Int32(index), &info) else {
            throw MultitouchError.noDevice
        }
        return TrackpadDevice(index: index,
                              familyID: info.familyID,
                              grid: grid(from: info),
                              isBuiltIn: info.builtIn)
    }

    private static func grid(from info: PMDeviceInfo) -> SensorGrid {
        let fallback = SensorGrid.appleBuiltInDefault
        // The private API sometimes reports zeroes before the device is fully
        // up; a plausible grid beats dividing by zero downstream.
        let cols = info.sensorCols > 0 ? Int(info.sensorCols) : fallback.cols
        let rows = info.sensorRows > 0 ? Int(info.sensorRows) : fallback.rows
        let width = info.surfaceWidth > 0
            ? Double(info.surfaceWidth) / 100 : fallback.widthMM
        let height = info.surfaceHeight > 0
            ? Double(info.surfaceHeight) / 100 : fallback.heightMM
        return SensorGrid(cols: cols, rows: rows, widthMM: width, heightMM: height)
    }

    private static func reasonText() -> String {
        pm_unavailable_reason().map { String(cString: $0) } ?? "unknown"
    }

    public func start(device: TrackpadDevice,
                      handler: @escaping @Sendable (TouchFrame) -> Void) throws {
        self.handler = handler
        self.device = device
        MultitouchStream.active = self

        let started = pm_start(Int32(device.index), { touches, count, timestamp, _, _ in
            MultitouchStream.deliver(touches: touches, count: count,
                                     timestamp: timestamp)
        }, nil)
        guard started else {
            self.handler = nil
            self.device = nil
            throw MultitouchError.startFailed(device.index)
        }
    }

    public func stop() {
        pm_stop()
        handler = nil
        MultitouchStream.active = nil
    }

    public var isRunning: Bool { pm_is_running() }

    private static func deliver(touches: UnsafePointer<PMTouch>?,
                                count: Int32,
                                timestamp: Double) {
        guard let stream = active, let handler = stream.handler else { return }

        var samples: [TouchSample] = []
        if let touches, count > 0 {
            samples.reserveCapacity(Int(count))
            for index in 0..<Int(count) {
                let touch = touches[index]
                guard let state = TouchState(rawValue: touch.state) else { continue }
                samples.append(TouchSample(
                    hardwareID: touch.identifier,
                    state: state,
                    position: Point(x: Double(touch.normalized.position.x),
                                    y: Double(touch.normalized.position.y)),
                    velocity: Point(x: Double(touch.normalized.velocity.x),
                                    y: Double(touch.normalized.velocity.y)),
                    size: Double(touch.size)))
            }
        }
        handler(TouchFrame(timestamp: timestamp, samples: samples))
    }
}
