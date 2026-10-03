import PadmendCore

func runGeometryTests() {
  suite("Sensor geometry") {
    let grid = SensorGrid(cols: 26, rows: 18, widthMM: 121.9, heightMM: 74.1)

        test("cell lookup covers the full range and clamps out-of-range input") {
        expectEq(grid.cell(at: Point(x: 0, y: 0)), Cell(col: 0, row: 0))
        expectEq(grid.cell(at: Point(x: 0.999, y: 0.999)), Cell(col: 25, row: 17))
        // The hardware does occasionally report slightly out-of-bounds
        // normalized values, which must clamp rather than wrap or trap.
        expectEq(grid.cell(at: Point(x: 1.4, y: -0.3)), Cell(col: 25, row: 0))
    }

        test("cell index round-trips") {
        for index in 0..<grid.cellCount {
            expectEq(grid.index(of: grid.cell(atIndex: index)), index)
        }
    }

        test("a cell centre resolves back to its own cell") {
        for index in 0..<grid.cellCount {
            let cell = grid.cell(atIndex: index)
            expectEq(grid.cell(at: grid.center(of: cell)), cell)
        }
    }

        test("a segment enumerates every intervening cell") {
        let cells = grid.cells(along: grid.center(of: Cell(col: 2, row: 9)),
                               to: grid.center(of: Cell(col: 8, row: 9)))
        expectEq(cells.map(\.col), [2, 3, 4, 5, 6, 7, 8])
        expect(cells.allSatisfy { $0.row == 9 })
    }

        test("a zero-length segment yields exactly one cell") {
        let p = grid.center(of: Cell(col: 4, row: 4))
        expectEq(grid.cells(along: p, to: p), [Cell(col: 4, row: 4)])
    }

        test("a diagonal segment stays connected") {
        let cells = grid.cells(along: grid.center(of: Cell(col: 0, row: 0)),
                               to: grid.center(of: Cell(col: 10, row: 7)))
        expectEq(cells.first, Cell(col: 0, row: 0))
        expectEq(cells.last, Cell(col: 10, row: 7))
        // No gaps: consecutive cells must touch, or a dropout could slip
        // through the transit accounting unnoticed.
        for (a, b) in zip(cells, cells.dropFirst()) {
            expect(abs(a.col - b.col) <= 1 && abs(a.row - b.row) <= 1)
        }
    }

        test("normalized displacement converts to millimetres") {
        let mm = grid.millimetres(Point(x: 0.5, y: 0.5))
        expectClose(mm.x, 60.95, 0.001)
        expectClose(mm.y, 37.05, 0.001)
    }
}
}
