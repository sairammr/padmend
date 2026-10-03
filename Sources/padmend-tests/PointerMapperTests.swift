import Foundation
import PadmendCore

func runPointerMapperTests() {
  suite("Pointer mapping") {
    let grid = SensorGrid.appleBuiltInDefault

    test("acceleration gain is bounded and rises with speed") {
        let mapper = PointerMapper(deadMap: .empty(grid: grid))
        let config = mapper.config

        expectClose(mapper.accelerationGain(forSpeed: 0), config.minGain, 1e-9)
        expectClose(mapper.accelerationGain(forSpeed: config.accelLowSpeed),
                    config.minGain, 1e-9)
        expectClose(mapper.accelerationGain(forSpeed: config.accelHighSpeed),
                    config.maxGain, 1e-9)
        expectClose(mapper.accelerationGain(forSpeed: 10_000), config.maxGain, 1e-9)

        var previous = -Double.infinity
        for speed in stride(from: 0.0, through: 400, by: 5) {
            let gain = mapper.accelerationGain(forSpeed: speed)
            expect(gain >= previous - 1e-12, "gain fell at \(speed) mm/s")
            expect(gain >= config.minGain - 1e-12 && gain <= config.maxGain + 1e-12)
            previous = gain
        }
    }

    test("a healthy pad gets no compensation") {
        let mapper = PointerMapper(deadMap: .empty(grid: grid))
        expectClose(mapper.compensation.x, 1)
        expectClose(mapper.compensation.y, 1)
    }

    test("lost surface is compensated by the reciprocal of what remains") {
        // Three of 26 columns severed leaves 23/26 of the width.
        let mapper = PointerMapper(deadMap: deadMap(grid: grid, deadColumns: [0, 1, 2]))
        expectClose(mapper.compensation.x, 26.0 / 23.0, 1e-9)
        expectClose(mapper.compensation.y, 1, 1e-9)
    }

    test("compensation is capped however much surface is lost") {
        var health = Array(repeating: CellHealth.dead, count: grid.cellCount)
        health[grid.index(of: Cell(col: 25, row: 0))] = .live
        let ruined = DeadMap(grid: grid, health: health,
                             condemnedColumns: Set(0..<25), condemnedRows: [])
        let mapper = PointerMapper(deadMap: ruined)
        expectClose(mapper.compensation.x, mapper.config.maxCompensation, 1e-9)
    }

    test("compensation can be switched off") {
        var config = PointerConfig()
        config.compensateForDeadArea = false
        let mapper = PointerMapper(deadMap: deadMap(grid: grid, deadColumns: [0, 1, 2]),
                                   config: config)
        expectClose(mapper.compensation.x, 1)
    }

    test("vertical motion is inverted into screen coordinates") {
        let mapper = PointerMapper(deadMap: .empty(grid: grid))
        // Finger moving away from the user must move the pointer up the screen,
        // which is negative in Core Graphics.
        let movement = mapper.pointMovement(delta: Point(x: 0, y: 0.1), dt: 1.0 / 90)
        expect(movement.y < 0, "got \(movement.y)")

        var upright = PointerConfig()
        upright.invertY = false
        let unflipped = PointerMapper(deadMap: .empty(grid: grid), config: upright)
        expect(unflipped.pointMovement(delta: Point(x: 0, y: 0.1),
                                       dt: 1.0 / 90).y > 0)
    }

    test("compensation makes the full screen reachable from a narrowed pad") {
        let healthy = PointerMapper(deadMap: .empty(grid: grid))
        // Five severed columns: the finger can only travel 21/26 of the width.
        let damaged = PointerMapper(deadMap: deadMap(grid: grid,
                                                     deadColumns: [8, 9, 10, 11, 12]))
        let dt = 1.0 / 90

        let fullSweep = healthy.pointMovement(delta: Point(x: 1.0, y: 0), dt: dt).x
        let narrowSweep = damaged.pointMovement(delta: Point(x: 21.0 / 26.0, y: 0),
                                                dt: dt).x
        // Travelling only the live part of the pad should now cover at least as
        // much screen as a whole-pad sweep used to.
        expect(narrowSweep >= fullSweep * 0.95,
               "narrowed sweep covers \(narrowSweep) vs \(fullSweep)")
    }

    test("sub-pixel movement accumulates instead of being dropped") {
        var mapper = PointerMapper(deadMap: .empty(grid: grid))
        let dt = 1.0 / 90
        // A delta small enough that one frame rounds to zero points.
        let crawl = Point(x: 0.0004, y: 0)
        expect(abs(mapper.pointMovement(delta: crawl, dt: dt).x) < 1,
               "this test needs a delta below one point per frame")

        var total = 0
        for _ in 0..<200 { total += mapper.step(delta: crawl, dt: dt).dx }
        expect(total > 0, "slow motion was discarded entirely")
    }

    test("accumulated steps track the fractional movement they came from")  {
        var mapper = PointerMapper(deadMap: .empty(grid: grid))
        let dt = 1.0 / 90
        let delta = Point(x: 0.004, y: -0.003)

        var expectedX = 0.0
        var expectedY = 0.0
        var actualX = 0
        var actualY = 0
        for _ in 0..<300 {
            let fractional = mapper.pointMovement(delta: delta, dt: dt)
            expectedX += fractional.x
            expectedY += fractional.y
            let step = mapper.step(delta: delta, dt: dt)
            actualX += step.dx
            actualY += step.dy
        }
        // Accumulation may lag by at most the residual still held back.
        expect(abs(Double(actualX) - expectedX) <= 1.0,
               "x drifted: \(actualX) vs \(expectedX)")
        expect(abs(Double(actualY) - expectedY) <= 1.0,
               "y drifted: \(actualY) vs \(expectedY)")
    }

    test("negative movement rounds toward zero symmetrically") {
        var mapper = PointerMapper(deadMap: .empty(grid: grid))
        let dt = 1.0 / 90
        var forward = 0
        var backward = 0
        for _ in 0..<120 {
            forward += mapper.step(delta: Point(x: 0.002, y: 0), dt: dt).dx
        }
        mapper.flushResidual()
        for _ in 0..<120 {
            backward += mapper.step(delta: Point(x: -0.002, y: 0), dt: dt).dx
        }
        expect(abs(forward + backward) <= 1,
               "asymmetric rounding: \(forward) forward, \(backward) back")
    }

    test("flushing the residual stops one gesture bleeding into the next") {
        var mapper = PointerMapper(deadMap: .empty(grid: grid))
        let dt = 1.0 / 90
        _ = mapper.step(delta: Point(x: 0.0009, y: 0), dt: dt)
        mapper.flushResidual()
        var total = 0
        for _ in 0..<3 { total += mapper.step(delta: .zero, dt: dt).dx }
        expectEq(total, 0)
    }

    test("a zero time step does not produce a division blow-up") {
        let mapper = PointerMapper(deadMap: .empty(grid: grid))
        let movement = mapper.pointMovement(delta: Point(x: 0.01, y: 0.01), dt: 0)
        expect(movement.x.isFinite && movement.y.isFinite)
    }
  }
}
