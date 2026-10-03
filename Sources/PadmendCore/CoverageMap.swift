import Foundation

/// Calibration accumulator.
///
/// The hard part of finding a dead spot is telling it apart from a spot the
/// user simply never swept. This resolves that with two counters per cell:
///
/// - `hits`: a raw sample landed in the cell, so the cell is demonstrably alive.
/// - `transits`: a tracked finger's path crossed the cell without a sample
///   landing there, so the finger was demonstrably over the cell and the cell
///   said nothing.
///
/// A cell with transits and no hits is dead. A cell with neither is unknown,
/// and unknown is reported as unknown rather than guessed at.
public struct CoverageMap: Codable, Sendable {
    public let grid: SensorGrid
    public private(set) var hits: [Int]
    public private(set) var transits: [Int]

    public init(grid: SensorGrid) {
        self.grid = grid
        self.hits = Array(repeating: 0, count: grid.cellCount)
        self.transits = Array(repeating: 0, count: grid.cellCount)
    }

    public func hits(at cell: Cell) -> Int { hits[grid.index(of: cell)] }
    public func transits(at cell: Cell) -> Int { transits[grid.index(of: cell)] }

    /// Records a sample that the hardware actually reported.
    public mutating func recordHit(at point: Point) {
        hits[grid.index(of: grid.cell(at: point))] += 1
    }

    /// Records that a finger travelled from `from` to `to`. Cells along the way
    /// that did not produce their own sample are credited as transits.
    ///
    /// Both endpoints are excluded: they are where samples exist, so crediting
    /// them as transits would make every live cell look partly flaky.
    public mutating func recordTransit(from: Point, to: Point) {
        let startCell = grid.cell(at: from)
        let endCell = grid.cell(at: to)
        for cell in grid.cells(along: from, to: to) {
            if cell == startCell || cell == endCell { continue }
            transits[grid.index(of: cell)] += 1
        }
    }

    /// Fraction of cells with any evidence at all. Drives the "keep sweeping"
    /// progress readout during calibration.
    public var evidenceCoverage: Double {
        let known = (0..<grid.cellCount).count { hits[$0] > 0 || transits[$0] > 0 }
        return Double(known) / Double(grid.cellCount)
    }

    public mutating func reset() {
        hits = Array(repeating: 0, count: grid.cellCount)
        transits = Array(repeating: 0, count: grid.cellCount)
    }
}
