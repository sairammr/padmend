import Foundation
import PadmendCore

/// Drives the whole chain the way the engine does — tracker, then pointer
/// mapper or gesture recognizer — and measures what reaches the screen.
func runPipelineTests() {
  suite("Whole pipeline") {
    let grid = SensorGrid.appleBuiltInDefault

    struct Result {
        var pointsTravelled: Int
        var largestJump: Int
        var fingerUps: Int
        var fingerDowns: Int
        var suppressedTaps: Int
    }

    /// Sweeps a single finger and reports the pointer movement that results.
    func sweep(deadColumns: Set<Int>,
               mapKnows: Bool = true,
               from: Point,
               to: Point,
               seconds: Double = 0.4) -> Result {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = deadColumns
        let map = mapKnows
            ? deadMap(grid: grid, deadColumns: deadColumns)
            : DeadMap.empty(grid: grid)

        let tracker = ContactTracker(deadMap: map)
        var pointerMapper = PointerMapper(deadMap: map)

        var result = Result(pointsTravelled: 0, largestJump: 0,
                            fingerUps: 0, fingerDowns: 0, suppressedTaps: 0)
        var previous: Double? = nil

        for frame in sim.sweep(from: from, to: to, seconds: seconds) {
            let output = tracker.process(frame)
            let dt = previous.map { frame.timestamp - $0 } ?? 0
            previous = frame.timestamp

            if output.fingers.count == 1 {
                let step = pointerMapper.step(delta: output.fingers[0].delta, dt: dt)
                let magnitude = abs(step.dx) + abs(step.dy)
                result.pointsTravelled += magnitude
                result.largestJump = max(result.largestJump, magnitude)
            }
            for event in output.events {
                switch event {
                case .fingerUp: result.fingerUps += 1
                case .fingerDown: result.fingerDowns += 1
                case .phantomTapSuppressed: result.suppressedTaps += 1
                case .dropoutRepaired: break
                }
            }
        }
        return result
    }

    test("a healthy pad moves the pointer smoothly across the screen") {
        let result = sweep(deadColumns: [], from: Point(x: 0.15, y: 0.5),
                           to: Point(x: 0.85, y: 0.5))
        expect(result.pointsTravelled > 100,
               "only \(result.pointsTravelled) points of travel")
        expectEq(result.fingerDowns, 1)
        expectEq(result.fingerUps, 0)
    }

    test("a dead stripe neither stalls the pointer nor jumps it") {
        let healthy = sweep(deadColumns: [], from: Point(x: 0.15, y: 0.5),
                            to: Point(x: 0.85, y: 0.5))
        let damaged = sweep(deadColumns: [11], from: Point(x: 0.15, y: 0.5),
                            to: Point(x: 0.85, y: 0.5))

        // Travel is compensated, so crossing the damage covers at least as
        // much screen as the healthy pad did.
        expect(damaged.pointsTravelled >= healthy.pointsTravelled,
               "damaged \(damaged.pointsTravelled) vs healthy \(healthy.pointsTravelled)")
        // And it gets there without a visible jump.
        expect(damaged.largestJump <= healthy.largestJump * 3,
               "largest jump \(damaged.largestJump) vs \(healthy.largestJump) on a good pad")
        expectEq(damaged.fingerUps, 0, "the drag must not be broken")
        expectEq(damaged.fingerDowns, 1)
    }

    test("an uncalibrated pad is still usable, just not compensated") {
        let known = sweep(deadColumns: [11], mapKnows: true,
                          from: Point(x: 0.15, y: 0.5), to: Point(x: 0.85, y: 0.5))
        let unknown = sweep(deadColumns: [11], mapKnows: false,
                            from: Point(x: 0.15, y: 0.5), to: Point(x: 0.85, y: 0.5))
        expectEq(unknown.fingerUps, 0, "dropout repair works before calibration")
        expect(known.pointsTravelled >= unknown.pointsTravelled,
               "calibration should add reach, not remove it")
    }

    test("the whole screen is reachable from the part of the pad that works") {
        // Five columns gone from the middle. The finger only ever uses the
        // surface that still answers, and should still cross the screen.
        let damagedColumns: Set<Int> = [8, 9, 10, 11, 12]
        let map = deadMap(grid: grid, deadColumns: damagedColumns)
        var mapper = PointerMapper(deadMap: map)
        var healthyMapper = PointerMapper(deadMap: .empty(grid: grid))
        let dt = 1.0 / 90
        let frames = 36

        // Healthy pad: the finger sweeps the whole width.
        var healthyTotal = 0
        let healthyStep = Point(x: 1.0 / Double(frames), y: 0)
        for _ in 0..<frames {
            healthyTotal += healthyMapper.step(delta: healthyStep, dt: dt).dx
        }

        // Damaged pad: the finger only sweeps the 21 columns that still work.
        var damagedTotal = 0
        let damagedStep = Point(x: (21.0 / 26.0) / Double(frames), y: 0)
        for _ in 0..<frames {
            damagedTotal += mapper.step(delta: damagedStep, dt: dt).dx
        }

        expect(damagedTotal >= healthyTotal,
               "reachable travel fell from \(healthyTotal) to \(damagedTotal) points")
    }

    test("a flickering trace does not fire clicks or break a drag") {
        var sim = PadSimulator(grid: grid)
        sim.flakyColumns = [11]
        sim.flakyPeriod = 3
        let map = deadMap(grid: grid, flakyColumns: [11])
        let tracker = ContactTracker(deadMap: map)

        var downs = 0
        var ups = 0
        var suppressed = 0
        for frame in sim.sweep(from: Point(x: 0.3, y: 0.5),
                               to: Point(x: 0.6, y: 0.5), seconds: 0.6) {
            for event in tracker.process(frame).events {
                switch event {
                case .fingerDown: downs += 1
                case .fingerUp: ups += 1
                case .phantomTapSuppressed: suppressed += 1
                case .dropoutRepaired: break
                }
            }
        }
        expectEq(downs, 1, "the finger landed once")
        expectEq(ups, 0, "a flickering trace must not break the drag")
        expectEq(suppressed, 0, "a moving finger produces no taps to suppress")
    }

    test("scrolling survives a dropout under one of the two fingers") {
        let map = deadMap(grid: grid, deadColumns: [11])
        let tracker = ContactTracker(deadMap: map)
        var recognizer = GestureRecognizer(grid: grid)

        var time = 1_000.0
        let interval = 1.0 / 90
        var left = Point(x: 0.30, y: 0.30)
        var right = Point(x: 0.45, y: 0.30)
        var totalScroll = 0
        var phases: [GesturePhase] = []
        var hardwareIDs: (Int32, Int32) = (1, 2)

        for step in 0..<40 {
            left = left + Point(x: 0.004, y: 0.006)
            right = right + Point(x: 0.004, y: 0.006)

            var samples: [TouchSample] = [
                TouchSample(hardwareID: hardwareIDs.0, position: left)
            ]
            // The right finger crosses the severed column and vanishes for
            // three frames, coming back with a new identifier.
            let inDropout = (18...20).contains(step)
            if !inDropout {
                if step == 21 { hardwareIDs.1 = 7 }
                samples.append(TouchSample(hardwareID: hardwareIDs.1, position: right))
            }

            let output = tracker.process(TouchFrame(timestamp: time, samples: samples))
            for event in recognizer.update(fingers: output.fingers, dt: interval) {
                if case .scroll(let phase, _, let dy) = event {
                    phases.append(phase)
                    totalScroll += dy
                }
            }
            time += interval
        }

        expect(phases.contains(.began), "scrolling never started")
        expect(!phases.contains(.ended),
               "the dropout ended the scroll; phases were \(phases)")
        expect(abs(totalScroll) > 0, "no scrolling reached the screen")
    }
  }
}
