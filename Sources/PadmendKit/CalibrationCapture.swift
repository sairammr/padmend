import Foundation
import PadmendCore

/// Owns the calibration state that the contact-stream thread writes and the
/// interface reads.
///
/// This exists so neither the terminal nor the window has to hold mutable
/// state that two threads touch. Frames arrive on MultitouchSupport's thread
/// and the display refreshes on the main one, so the state belongs to neither
/// and lives here behind a lock instead.
public final class CalibrationCapture: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var coverage: CoverageMap
        public var fingers: [Point]
        public var repairedDropouts: Int
        public var frameCount: Int

        /// Fraction of the pad with any evidence yet.
        public var progress: Double { coverage.evidenceCoverage }
    }

    private let lock = NSLock()
    private let tracker: ContactTracker
    private var calibrator: Calibrator
    private var fingers: [Point] = []

    public init(grid: SensorGrid) {
        tracker = ContactTracker(deadMap: .empty(grid: grid), config: .calibration)
        calibrator = Calibrator(grid: grid)
    }

    public func ingest(_ frame: TouchFrame) {
        lock.lock()
        let output = tracker.process(frame)
        calibrator.ingest(frame: frame, output: output)
        fingers = output.fingers.map(\.position)
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(coverage: calibrator.coverage,
                        fingers: fingers,
                        repairedDropouts: calibrator.repairedDropouts,
                        frameCount: calibrator.frameCount)
    }

    public func makeDeadMap() -> DeadMap {
        lock.lock(); defer { lock.unlock() }
        return calibrator.makeDeadMap()
    }

    public func reset() {
        lock.lock()
        calibrator.reset()
        tracker.reset()
        fingers = []
        lock.unlock()
    }
}
