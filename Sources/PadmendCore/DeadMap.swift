import Foundation

public enum CellHealth: Int, Codable, Sendable {
    /// Reports touches reliably.
    case live = 0
    /// Reports touches sometimes. The worst kind: it produces the phantom
    /// lift/land churn that breaks drags and fires spurious clicks.
    case flaky = 1
    /// Never reports a touch the finger demonstrably made.
    case dead = 2
    /// No evidence either way.
    case unknown = 3

    /// Unknown is treated as usable. Shrinking the pointer's working area on
    /// the strength of no evidence would punish the user for an incomplete
    /// sweep.
    public var isUsable: Bool { self == .live || self == .unknown }
    public var isSuspect: Bool { self == .flaky || self == .dead }
}

/// Thresholds for turning a `CoverageMap` into a `DeadMap`. Exposed because
/// real sensors differ and the right numbers are an empirical question, not a
/// design-time one.
public struct DeadMapThresholds: Codable, Sendable {
    /// Evidence needed before a cell may be called dead.
    public var minTransitsForDead: Int
    /// Evidence needed before a cell may be called flaky.
    public var minSamplesForFlaky: Int
    /// At or above this hit rate a cell is live; below it, flaky.
    public var liveHitRate: Double
    /// Fraction of a trace's judged cells that must be suspect before the
    /// whole trace is condemned.
    public var stripeSuspectFraction: Double
    /// Minimum judged cells in a trace before the stripe rule may fire, as a
    /// fraction of that trace's length.
    public var stripeMinJudgedFraction: Double

    public init(minTransitsForDead: Int = 3,
                minSamplesForFlaky: Int = 4,
                liveHitRate: Double = 0.6,
                stripeSuspectFraction: Double = 0.6,
                stripeMinJudgedFraction: Double = 0.34) {
        self.minTransitsForDead = minTransitsForDead
        self.minSamplesForFlaky = minSamplesForFlaky
        self.liveHitRate = liveHitRate
        self.stripeSuspectFraction = stripeSuspectFraction
        self.stripeMinJudgedFraction = stripeMinJudgedFraction
    }

    public static let `default` = DeadMapThresholds()
}

/// A contiguous run of usable cells along one axis.
public struct LiveSpan: Equatable, Codable, Sendable {
    /// First usable index, inclusive.
    public var start: Int
    /// Last usable index, inclusive.
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public var length: Int { end - start + 1 }
}

/// The calibration result: per-cell health, the condemned traces, and the
/// usable extent of the surface.
public struct DeadMap: Codable, Sendable {
    public let grid: SensorGrid
    public private(set) var health: [CellHealth]
    /// Column indices condemned as a whole by the stripe rule.
    public private(set) var deadColumns: Set<Int>
    /// Row indices condemned as a whole by the stripe rule.
    public private(set) var deadRows: Set<Int>
    public let createdAt: Date

    public init(grid: SensorGrid,
                health: [CellHealth]? = nil,
                deadColumns: Set<Int> = [],
                deadRows: Set<Int> = [],
                createdAt: Date = Date()) {
        self.grid = grid
        self.health = health ?? Array(repeating: .unknown, count: grid.cellCount)
        self.deadColumns = deadColumns
        self.deadRows = deadRows
        self.createdAt = createdAt
    }

    /// A map that claims nothing. The engine still runs against this; it just
    /// has no dead-zone evidence to reason with.
    public static func empty(grid: SensorGrid) -> DeadMap { DeadMap(grid: grid) }

    public var isCalibrated: Bool { health.contains { $0 != .unknown } }

    public func health(at cell: Cell) -> CellHealth {
        guard grid.contains(cell) else { return .unknown }
        return health[grid.index(of: cell)]
    }

    public func health(at point: Point) -> CellHealth {
        health(at: grid.cell(at: point))
    }

    /// Whether the segment between two points crosses anything suspect. This is
    /// the evidence gate for re-associating a contact across a dropout: without
    /// it, two fingers landing in quick succession could be mistaken for one
    /// finger that flickered.
    public func segmentCrossesSuspectCell(from: Point, to: Point) -> Bool {
        grid.cells(along: from, to: to).contains { health(at: $0).isSuspect }
    }

    /// Whether `point` sits in or next to a suspect cell. Used to decide
    /// whether a short tap is plausibly a phantom.
    public func isNearSuspectCell(_ point: Point, radius: Int = 1) -> Bool {
        let c = grid.cell(at: point)
        for dcol in -radius...radius {
            for drow in -radius...radius {
                let probe = Cell(col: c.col + dcol, row: c.row + drow)
                guard grid.contains(probe) else { continue }
                if health(at: probe).isSuspect { return true }
            }
        }
        return false
    }

    // MARK: - Usable extent

    /// Longest contiguous run of columns that are usable for at least part of
    /// their length. Drives the horizontal pointer gain.
    public var usableColumnSpan: LiveSpan {
        longestSpan(count: grid.cols, isUsable: { col in
            !deadColumns.contains(col)
        })
    }

    public var usableRowSpan: LiveSpan {
        longestSpan(count: grid.rows, isUsable: { row in
            !deadRows.contains(row)
        })
    }

    /// Fraction of the surface width still reachable, in 0<f<=1.
    public var usableWidthFraction: Double {
        Double(grid.cols - deadColumns.count) / Double(grid.cols)
    }

    public var usableHeightFraction: Double {
        Double(grid.rows - deadRows.count) / Double(grid.rows)
    }

    private func longestSpan(count: Int, isUsable: (Int) -> Bool) -> LiveSpan {
        var best = LiveSpan(start: 0, end: count - 1)
        var bestLength = 0
        var runStart: Int? = nil
        for i in 0..<count {
            if isUsable(i) {
                if runStart == nil { runStart = i }
                let length = i - runStart! + 1
                if length > bestLength {
                    bestLength = length
                    best = LiveSpan(start: runStart!, end: i)
                }
            } else {
                runStart = nil
            }
        }
        return bestLength == 0 ? LiveSpan(start: 0, end: count - 1) : best
    }

    // MARK: - Classification

    /// Turns raw calibration evidence into a dead map.
    public static func classify(_ coverage: CoverageMap,
                                thresholds: DeadMapThresholds = .default) -> DeadMap {
        let grid = coverage.grid
        var health = Array(repeating: CellHealth.unknown, count: grid.cellCount)

        for index in 0..<grid.cellCount {
            let cell = grid.cell(atIndex: index)
            let hits = coverage.hits(at: cell)
            let transits = coverage.transits(at: cell)
            let opportunities = hits + transits

            if hits == 0 {
                // Silent. Dead only if the finger provably went over it.
                health[index] = transits >= thresholds.minTransitsForDead
                    ? .dead : .unknown
                continue
            }

            // It registered at least once, so the trace is not severed. The
            // question is only how often it registers.
            guard opportunities >= thresholds.minSamplesForFlaky else {
                health[index] = .live
                continue
            }
            let hitRate = Double(hits) / Double(opportunities)
            health[index] = hitRate >= thresholds.liveHitRate ? .live : .flaky
        }

        var map = DeadMap(grid: grid, health: health)
        map.condemnStripes(thresholds: thresholds)
        return map
    }

    /// A severed capacitive trace takes out a whole row or column. Detecting
    /// that pattern lets a short sweep condemn the entire trace, including the
    /// cells the user never reached — which is what makes calibration quick
    /// instead of a chore.
    public mutating func condemnStripes(thresholds: DeadMapThresholds = .default) {
        var columns = Set<Int>()
        for col in 0..<grid.cols {
            let states = (0..<grid.rows).map { health(at: Cell(col: col, row: $0)) }
            if isCondemned(states, length: grid.rows, thresholds: thresholds) {
                columns.insert(col)
            }
        }

        var rows = Set<Int>()
        for row in 0..<grid.rows {
            let states = (0..<grid.cols).map { health(at: Cell(col: $0, row: row)) }
            if isCondemned(states, length: grid.cols, thresholds: thresholds) {
                rows.insert(row)
            }
        }

        deadColumns = columns
        deadRows = rows

        // Propagate the verdict to every cell of a condemned trace, so the
        // tracker's suspect-cell checks see the whole stripe rather than only
        // the part that was swept.
        for col in columns {
            for row in 0..<grid.rows where health(at: Cell(col: col, row: row)) == .unknown {
                health[grid.index(of: Cell(col: col, row: row))] = .dead
            }
        }
        for row in rows {
            for col in 0..<grid.cols where health(at: Cell(col: col, row: row)) == .unknown {
                health[grid.index(of: Cell(col: col, row: row))] = .dead
            }
        }
    }

    private func isCondemned(_ states: [CellHealth],
                             length: Int,
                             thresholds: DeadMapThresholds) -> Bool {
        let judged = states.filter { $0 != .unknown }
        let minJudged = max(2, Int(Double(length) * thresholds.stripeMinJudgedFraction))
        guard judged.count >= minJudged else { return false }
        let suspect = judged.count { $0.isSuspect }
        return Double(suspect) / Double(judged.count) >= thresholds.stripeSuspectFraction
    }
}
