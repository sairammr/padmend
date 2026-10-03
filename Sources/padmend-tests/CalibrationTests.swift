import Foundation
import PadmendCore

func runCalibrationTests() {
  suite("Calibration, end to end") {
    let grid = SensorGrid.appleBuiltInDefault

    /// Drives a full raster sweep of the pad through the real tracker and the
    /// real calibrator, exactly as the calibration UI does, and returns the
    /// dead map that falls out.
    func calibrate(deadColumns: Set<Int> = [],
                   flakyColumns: Set<Int> = [],
                   rows: Range<Int>? = nil,
                   passes: Int = 4) -> DeadMap {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = deadColumns
        sim.flakyColumns = flakyColumns
        let tracker = ContactTracker(deadMap: .empty(grid: grid),
                                     config: .calibration)
        let calibrator = Calibrator(grid: grid)

        for _ in 0..<passes {
            for row in (rows ?? 0..<grid.rows) {
                let y = grid.center(of: Cell(col: 0, row: row)).y
                var frames = sim.sweep(from: Point(x: 0.02, y: y),
                                       to: Point(x: 0.98, y: y),
                                       seconds: 0.9)
                frames.append(sim.liftFrame(at: Point(x: 0.98, y: y)))
                frames.append(sim.emptyFrame())
                for frame in frames {
                    calibrator.ingest(frame: frame, output: tracker.process(frame))
                }
            }
        }
        return calibrator.makeDeadMap()
    }

    test("a raster sweep of a healthy pad condemns nothing") {
        let map = calibrate()
        expect(map.condemnedColumns.isEmpty, "condemned \(map.condemnedColumns.sorted())")
        expect(map.condemnedRows.isEmpty, "condemned \(map.condemnedRows.sorted())")
        expect(!map.health.contains(.dead))
        expectClose(map.usableWidthFraction, 1)
    }

    test("a raster sweep finds a severed column") {
        let map = calibrate(deadColumns: [11])
        expectEq(map.condemnedColumns, [11])
        expect(map.condemnedRows.isEmpty)
        expectEq(map.health(at: Cell(col: 11, row: 9)), .dead)
        expectEq(map.health(at: Cell(col: 10, row: 9)), .live)
    }

    test("a raster sweep finds two severed columns")  {
        let map = calibrate(deadColumns: [4, 17])
        expectEq(map.condemnedColumns, [4, 17])
    }

    test("a raster sweep tells a flaky column apart from a severed one") {
        let map = calibrate(flakyColumns: [7])
        // Condemned, because a trace that answers one time in three is no
        // more usable than one that never answers — but reported as flaky, not
        // promoted to dead, because that is what it actually is.
        expect(map.condemnedColumns.contains(7))
        expectEq(map.health(at: Cell(col: 7, row: 9)), .flaky)
        expect(!map.health.contains(.dead), "nothing here is severed")
    }

    test("sweeping only part of the pad still condemns the whole trace") {
        let map = calibrate(deadColumns: [11], rows: 2..<8)
        expect(map.condemnedColumns.contains(11))
        expectEq(map.health(at: Cell(col: 11, row: 16)), .dead,
                 "the stripe rule should cover rows that were never swept")
    }

    test("a wide band of damage is detected across its whole width") {
        // Regression: evidence used to be credited at the tracker's
        // extrapolated positions, whose velocity decays during a dropout, so a
        // band this wide was only ever detected two columns deep.
        let map = calibrate(deadColumns: [9, 10, 11, 12])
        expectEq(map.condemnedColumns, [9, 10, 11, 12])
        let mapper = PointerMapper(deadMap: map)
        expectEq(map.condemnedColumns.count, 4)
        expectClose(mapper.compensation.x, 26.0 / 22.0, 1e-9)
    }

    test("the calibrator reports progress and what is still unexplored") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: .empty(grid: grid), config: .calibration)
        let calibrator = Calibrator(grid: grid)
        expectClose(calibrator.progress, 0)
        expectEq(calibrator.unexploredCells().count, grid.cellCount)

        let y = grid.center(of: Cell(col: 0, row: 0)).y
        for frame in sim.sweep(from: Point(x: 0.02, y: y),
                              to: Point(x: 0.98, y: y), seconds: 0.9) {
            calibrator.ingest(frame: frame, output: tracker.process(frame))
        }
        expect(calibrator.progress > 0 && calibrator.progress < 1)
        expectEq(calibrator.unexploredCells().count,
                 grid.cellCount - grid.cols,
                 "one swept row should leave exactly the other rows unexplored")
    }

    test("the calibrator counts the dropouts it repaired") {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = [11]
        let tracker = ContactTracker(deadMap: .empty(grid: grid), config: .calibration)
        let calibrator = Calibrator(grid: grid)
        let y = 0.5
        for frame in sim.sweep(from: Point(x: 0.02, y: y),
                              to: Point(x: 0.98, y: y), seconds: 0.9) {
            calibrator.ingest(frame: frame, output: tracker.process(frame))
        }
        expect(calibrator.repairedDropouts >= 1)
    }

    test("resetting the calibrator discards the evidence") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: .empty(grid: grid), config: .calibration)
        let calibrator = Calibrator(grid: grid)
        for frame in sim.sweep(from: Point(x: 0.02, y: 0.5),
                              to: Point(x: 0.98, y: 0.5), seconds: 0.9) {
            calibrator.ingest(frame: frame, output: tracker.process(frame))
        }
        expect(calibrator.progress > 0)
        calibrator.reset()
        expectClose(calibrator.progress, 0)
        expectEq(calibrator.frameCount, 0)
    }
  }
}
