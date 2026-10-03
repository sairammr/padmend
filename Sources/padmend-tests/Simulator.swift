import Foundation
import PadmendCore

/// Generates a synthetic contact stream for a trackpad with chosen defects, so
/// tracker behaviour can be tested without a damaged pad in the loop.
struct PadSimulator {
    var grid: SensorGrid
    /// Columns that report nothing at all.
    var deadColumns: Set<Int> = []
    /// Columns that report on one frame in `flakyPeriod`.
    var flakyColumns: Set<Int> = []
    var flakyPeriod: Int = 3
    var frameRate: Double = 90
    /// Whether the hardware hands back a fresh contact identifier after a
    /// dropout, which is what makes a flicker look like a lift and a land.
    var reassignsIDAfterDropout = true

    private(set) var time: Double = 1_000
    private var hardwareID: Int32 = 10
    private var frameIndex = 0
    private var wasSilent = false

    init(grid: SensorGrid = .appleBuiltInDefault) {
        self.grid = grid
    }

    var frameInterval: Double { 1 / frameRate }

    private func isSilent(_ point: Point) -> Bool {
        let col = grid.cell(at: point).col
        if deadColumns.contains(col) { return true }
        if flakyColumns.contains(col) { return frameIndex % flakyPeriod != 0 }
        return false
    }

    /// One frame with a single finger at `point`, or an empty frame when the
    /// sensor is silent there.
    mutating func frame(at point: Point, state: TouchState = .touching) -> TouchFrame {
        defer {
            time += frameInterval
            frameIndex += 1
        }
        guard !isSilent(point) else {
            wasSilent = true
            return TouchFrame(timestamp: time, samples: [])
        }
        if wasSilent, reassignsIDAfterDropout {
            hardwareID += 1
            wasSilent = false
        }
        return TouchFrame(timestamp: time,
                          samples: [TouchSample(hardwareID: hardwareID,
                                                state: state,
                                                position: point)])
    }

    /// An explicitly empty frame, i.e. nothing on the glass.
    mutating func emptyFrame() -> TouchFrame {
        defer {
            time += frameInterval
            frameIndex += 1
        }
        return TouchFrame(timestamp: time, samples: [])
    }

    /// A frame reporting an affirmative lift at `point`.
    mutating func liftFrame(at point: Point) -> TouchFrame {
        defer {
            time += frameInterval
            frameIndex += 1
        }
        return TouchFrame(timestamp: time,
                          samples: [TouchSample(hardwareID: hardwareID,
                                                state: .breakTouch,
                                                position: point)])
    }

    /// A straight sweep sampled at the frame rate.
    mutating func sweep(from: Point, to: Point, seconds: Double) -> [TouchFrame] {
        let count = max(2, Int((seconds * frameRate).rounded()))
        return (0..<count).map { step in
            let t = Double(step) / Double(count - 1)
            return frame(at: Point(x: from.x + (to.x - from.x) * t,
                                   y: from.y + (to.y - from.y) * t))
        }
    }

    mutating func hold(at point: Point, seconds: Double) -> [TouchFrame] {
        let count = max(1, Int((seconds * frameRate).rounded()))
        return (0..<count).map { _ in frame(at: point) }
    }
}

/// A dead map with the given columns severed and everything else healthy.
func deadMap(grid: SensorGrid = .appleBuiltInDefault,
             deadColumns: Set<Int> = [],
             flakyColumns: Set<Int> = []) -> DeadMap {
    var health = Array(repeating: CellHealth.live, count: grid.cellCount)
    for col in deadColumns {
        for row in 0..<grid.rows {
            health[grid.index(of: Cell(col: col, row: row))] = .dead
        }
    }
    for col in flakyColumns {
        for row in 0..<grid.rows {
            health[grid.index(of: Cell(col: col, row: row))] = .flaky
        }
    }
    return DeadMap(grid: grid, health: health,
                   condemnedColumns: deadColumns.union(flakyColumns),
                   condemnedRows: [])
}

extension Array where Element == TrackerOutput {
    var allEvents: [TrackerEvent] { flatMap(\.events) }

    var fingerDownCount: Int {
        allEvents.count { if case .fingerDown = $0 { return true } else { return false } }
    }

    var fingerUpCount: Int {
        allEvents.count { if case .fingerUp = $0 { return true } else { return false } }
    }

    var repairCount: Int {
        allEvents.count { if case .dropoutRepaired = $0 { return true } else { return false } }
    }

    var suppressedTapCount: Int {
        allEvents.count {
            if case .phantomTapSuppressed = $0 { return true } else { return false }
        }
    }

    /// Largest single-frame pointer jump, which is how a teleport shows up.
    var maxFrameDelta: Double {
        flatMap(\.fingers).map(\.delta.magnitude).max() ?? 0
    }

    /// Total travelled distance as the engine would integrate it.
    var integratedDistance: Double {
        flatMap(\.fingers).reduce(0) { $0 + $1.delta.magnitude }
    }

    var distinctFingerIDs: Set<Int> { Set(flatMap(\.fingers).map(\.id)) }
}
