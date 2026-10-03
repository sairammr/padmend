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

    /// Records one frame on which the sensor reported nothing while the finger
    /// was, by the tracker's reckoning, over `point`.
    ///
    /// Attributing a dropout frame by frame rather than by path geometry
    /// matters: when a contact vanishes between two neighbouring cells there
    /// is no interior to blame, and splitting the blame across both would make
    /// healthy cells beside a damaged trace look damaged. The tracker already
    /// extrapolates a position for each silent frame, which is a direct answer
    /// to "where was the finger when nothing was reported".
    public mutating func recordSilentFrame(at point: Point) {
        transits[grid.index(of: grid.cell(at: point))] += 1
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
