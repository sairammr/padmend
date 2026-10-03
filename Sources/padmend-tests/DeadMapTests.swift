import Foundation
import PadmendCore

func runDeadMapTests() {
  suite("Dead map classification") {
    let grid = SensorGrid(cols: 26, rows: 18, widthMM: 121.9, heightMM: 74.1)

    /// Simulates one horizontal sweep at `row`. Columns in `deadColumns`
    /// report nothing at all; columns in `flakyColumns` report on one pass in
    /// three. Gaps between reported samples are credited as transits, exactly
    /// as the live calibrator does.
    func sweepRow(_ row: Int,
                          into coverage: inout CoverageMap,
                          deadColumns: Set<Int> = [],
                          flakyColumns: Set<Int> = [],
                          deadCells: Set<Cell> = [],
                          pass: Int = 0) {
        var lastReported: Point? = nil
        for col in 0..<grid.cols {
            let cell = Cell(col: col, row: row)
            let point = grid.center(of: cell)
            let silent = deadColumns.contains(col)
                || deadCells.contains(cell)
                || (flakyColumns.contains(col) && pass % 3 != 0)
            if silent { continue }
            if let previous = lastReported {
                coverage.recordTransit(from: previous, to: point)
            }
            coverage.recordHit(at: point)
            lastReported = point
        }
    }

    func fullSweep(deadColumns: Set<Int> = [],
                           flakyColumns: Set<Int> = [],
                           deadCells: Set<Cell> = [],
                           rows: Range<Int>? = nil,
                           passes: Int = 5) -> CoverageMap {
        var coverage = CoverageMap(grid: grid)
        for pass in 0..<passes {
            for row in (rows ?? 0..<grid.rows) {
                sweepRow(row, into: &coverage, deadColumns: deadColumns,
                         flakyColumns: flakyColumns, deadCells: deadCells,
                         pass: pass)
            }
        }
        return coverage
    }

        test("a cell the finger crossed but never registered is dead") {
        let map = DeadMap.classify(fullSweep(deadColumns: [11]))
        expectEq(map.health(at: Cell(col: 11, row: 9)), .dead)
        expectEq(map.health(at: Cell(col: 10, row: 9)), .live)
        expectEq(map.health(at: Cell(col: 12, row: 9)), .live)
    }

        test("a cell that answers sometimes is flaky, not dead") {
        let map = DeadMap.classify(fullSweep(flakyColumns: [7], passes: 9))
        expectEq(map.health(at: Cell(col: 7, row: 4)), .flaky)
        expectEq(map.health(at: Cell(col: 6, row: 4)), .live)
    }

        test("a cell with no evidence stays unknown") {
        var coverage = CoverageMap(grid: grid)
        sweepRow(0, into: &coverage)
        let map = DeadMap.classify(coverage)
        expectEq(map.health(at: Cell(col: 13, row: 17)), .unknown)
    }

        test("unknown counts as usable, so a partial sweep does not shrink the pad") {
        expect(CellHealth.unknown.isUsable)
        expect(!CellHealth.unknown.isSuspect)
        expect(CellHealth.live.isUsable)
        expect(CellHealth.dead.isSuspect)
        expect(CellHealth.flaky.isSuspect)
    }

        test("the stripe rule condemns the unswept part of a severed column") {
        // Only the bottom third of the pad was swept.
        let map = DeadMap.classify(fullSweep(deadColumns: [11], rows: 0..<6))
        expect(map.deadColumns.contains(11))
        expectEq(map.health(at: Cell(col: 11, row: 17)), .dead)
        expectEq(map.health(at: Cell(col: 12, row: 17)), .unknown)
    }

        test("the stripe rule condemns a severed row too") {
        var coverage = CoverageMap(grid: grid)
        // Vertical sweeps, so a dead row shows up as a gap along the path.
        for pass in 0..<5 {
            for col in 0..<grid.cols {
                var lastReported: Point? = nil
                for row in 0..<grid.rows {
                    if row == 5 { continue }
                    let point = grid.center(of: Cell(col: col, row: row))
                    if let previous = lastReported {
                        coverage.recordTransit(from: previous, to: point)
                    }
                    coverage.recordHit(at: point)
                    lastReported = point
                }
            }
            _ = pass
        }
        let map = DeadMap.classify(coverage)
        expect(map.deadRows.contains(5))
        expect(map.deadColumns.isEmpty)
    }

        test("one dead cell is not a severed trace") {
        let map = DeadMap.classify(
            fullSweep(deadCells: [Cell(col: 11, row: 9)], passes: 6))
        expectEq(map.health(at: Cell(col: 11, row: 9)), .dead)
        expect(!map.deadColumns.contains(11))
        expectEq(map.health(at: Cell(col: 11, row: 2)), .live)
    }

        test("a clean pad is condemned nowhere") {
        let map = DeadMap.classify(fullSweep())
        expect(map.deadColumns.isEmpty)
        expect(map.deadRows.isEmpty)
        expect(!map.health.contains(.dead))
        expect(!map.health.contains(.flaky))
    }

        test("usable spans and fractions reflect the condemned traces") {
        let map = DeadMap(grid: grid,
                          health: Array(repeating: .live, count: grid.cellCount),
                          deadColumns: [0, 1, 2])
        expectEq(map.usableColumnSpan, LiveSpan(start: 3, end: 25))
        expectClose(map.usableWidthFraction, 23.0 / 26.0)
        expectClose(map.usableHeightFraction, 1)
        expectEq(DeadMap(grid: grid).usableColumnSpan, LiveSpan(start: 0, end: 25))
    }

        test("the longest usable span wins when a stripe splits the pad") {
        let map = DeadMap(grid: grid, deadColumns: [8])
        expectEq(map.usableColumnSpan, LiveSpan(start: 9, end: 25))
    }

        test("suspect-cell queries find a dead cell on a path and nearby") {
        var health = Array(repeating: CellHealth.live, count: grid.cellCount)
        health[grid.index(of: Cell(col: 11, row: 9))] = .dead
        let map = DeadMap(grid: grid, health: health)

        expect(map.segmentCrossesSuspectCell(
            from: grid.center(of: Cell(col: 9, row: 9)),
            to: grid.center(of: Cell(col: 13, row: 9))))
        expect(!map.segmentCrossesSuspectCell(
            from: grid.center(of: Cell(col: 9, row: 2)),
            to: grid.center(of: Cell(col: 13, row: 2))))
        expect(map.isNearSuspectCell(grid.center(of: Cell(col: 10, row: 9))))
        expect(!map.isNearSuspectCell(grid.center(of: Cell(col: 5, row: 2))))
    }

        test("a map survives a round trip through JSON") {
        let original = DeadMap.classify(fullSweep(deadColumns: [11]))
        let restored = try JSONDecoder().decode(
            DeadMap.self, from: JSONEncoder().encode(original))
        expectEq(restored.deadColumns, original.deadColumns)
        expectEq(restored.health, original.health)
        expectEq(restored.grid, original.grid)
    }

        test("coverage reports how much of the pad has been explored") {
        var coverage = CoverageMap(grid: grid)
        expectEq(coverage.evidenceCoverage, 0)
        for row in 0..<grid.rows { sweepRow(row, into: &coverage) }
        expectEq(coverage.evidenceCoverage, 1)
        coverage.reset()
        expectEq(coverage.evidenceCoverage, 0)
    }

        test("transits are not credited to the cells that produced samples") {
        var coverage = CoverageMap(grid: grid)
        let from = grid.center(of: Cell(col: 4, row: 4))
        let to = grid.center(of: Cell(col: 7, row: 4))
        coverage.recordHit(at: from)
        coverage.recordTransit(from: from, to: to)
        coverage.recordHit(at: to)

        expectEq(coverage.transits(at: Cell(col: 4, row: 4)), 0)
        expectEq(coverage.transits(at: Cell(col: 7, row: 4)), 0)
        expectEq(coverage.transits(at: Cell(col: 5, row: 4)), 1)
        expectEq(coverage.transits(at: Cell(col: 6, row: 4)), 1)
    }
}
}
