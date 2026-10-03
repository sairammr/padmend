import Foundation
import PadmendCore

func runContactTrackerTests() {
  suite("Contact tracker") {
    let grid = SensorGrid.appleBuiltInDefault

    /// Column 11 severed: a ~4.7 mm vertical stripe across the middle of the
    /// pad, which is the defect this project was written for.
    func midStripe() -> DeadMap { deadMap(grid: grid, deadColumns: [11]) }

    func run(_ tracker: ContactTracker, _ frames: [TouchFrame]) -> [TrackerOutput] {
        frames.map { tracker.process($0) }
    }

    test("a clean sweep on a healthy pad produces one finger and no churn") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: deadMap(grid: grid))
        let outputs = run(tracker, sim.sweep(from: Point(x: 0.2, y: 0.5),
                                            to: Point(x: 0.8, y: 0.5),
                                            seconds: 0.4))
        expectEq(outputs.fingerDownCount, 1)
        expectEq(outputs.repairCount, 0)
        expectEq(outputs.distinctFingerIDs.count, 1)
        // Integrated motion must match the real displacement; this is what the
        // pointer will actually travel.
        expectClose(outputs.integratedDistance, 0.6, 0.01)
    }

    test("crossing a dead stripe does not report a lift or a land") {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = [11]
        let tracker = ContactTracker(deadMap: midStripe())
        let outputs = run(tracker, sim.sweep(from: Point(x: 0.2, y: 0.5),
                                             to: Point(x: 0.8, y: 0.5),
                                             seconds: 0.4))

        expectEq(outputs.fingerDownCount, 1, "the finger landed once")
        expectEq(outputs.fingerUpCount, 0, "the finger never left the glass")
        expect(outputs.repairCount >= 1, "the dropout should be recognised and repaired")
        expectEq(outputs.distinctFingerIDs.count, 1, "identity must survive the stripe")
    }

    test("the pointer keeps moving while the sensor is silent") {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = [11]
        let tracker = ContactTracker(deadMap: midStripe())
        let outputs = run(tracker, sim.sweep(from: Point(x: 0.2, y: 0.5),
                                             to: Point(x: 0.8, y: 0.5),
                                             seconds: 0.4))

        let coasting = outputs.flatMap(\.fingers).filter(\.isCoasting)
        expect(!coasting.isEmpty, "some frames should have been extrapolated")
        let coastedDistance = coasting.reduce(0) { $0 + $1.delta.magnitude }
        expect(coastedDistance > 0.01,
               "coasting moved only \(coastedDistance); the cursor would have stalled")
    }

    test("re-acquiring after a dropout does not teleport the pointer") {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = [11]
        let tracker = ContactTracker(deadMap: midStripe())
        let outputs = run(tracker, sim.sweep(from: Point(x: 0.2, y: 0.5),
                                             to: Point(x: 0.8, y: 0.5),
                                             seconds: 0.4))

        // A 0.6-wide sweep over 0.4 s at 90 Hz moves ~0.017 per frame. Anything
        // several times that is a visible jump on screen.
        expect(outputs.maxFrameDelta < 0.05,
               "largest single-frame jump was \(outputs.maxFrameDelta)")
    }

    test("total travel across a dead stripe stays close to the real distance") {
        var clean = PadSimulator(grid: grid)
        let cleanTotal = run(ContactTracker(deadMap: deadMap(grid: grid)),
                             clean.sweep(from: Point(x: 0.2, y: 0.5),
                                         to: Point(x: 0.8, y: 0.5),
                                         seconds: 0.4)).integratedDistance

        var broken = PadSimulator(grid: grid)
        broken.deadColumns = [11]
        let brokenTotal = run(ContactTracker(deadMap: midStripe()),
                              broken.sweep(from: Point(x: 0.2, y: 0.5),
                                           to: Point(x: 0.8, y: 0.5),
                                           seconds: 0.4)).integratedDistance

        expect(abs(brokenTotal - cleanTotal) < 0.12,
               "repaired travel \(brokenTotal) vs clean \(cleanTotal)")
    }

    test("an affirmative lift ends the finger at once and never coasts") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: midStripe())
        var frames = sim.sweep(from: Point(x: 0.3, y: 0.5),
                               to: Point(x: 0.45, y: 0.5), seconds: 0.1)
        frames.append(sim.liftFrame(at: Point(x: 0.45, y: 0.5)))
        frames.append(sim.emptyFrame())
        let outputs = run(tracker, frames)

        expectEq(outputs.fingerUpCount, 1)
        expectEq(outputs.suppressedTapCount, 0)
        expectEq(outputs.last?.fingers.count, 0, "nothing should remain on the glass")
    }

    test("a contact vanishing over healthy area is a real lift, not a dropout") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: midStripe())
        // Columns 10 and 12 neighbour the severed column 11 and so count as
        // suspect; this sweep stays well clear of it.
        var frames = sim.sweep(from: Point(x: 0.60, y: 0.5),
                               to: Point(x: 0.70, y: 0.5), seconds: 0.2)
        // Hardware simply stops reporting, far from the damaged stripe.
        frames.append(sim.emptyFrame())
        let outputs = run(tracker, frames)

        expectEq(outputs.fingerUpCount, 1,
                 "waiting out the grace window here would add lag to every lift")
        expectEq(outputs.last?.fingers.count, 0)
    }

    test("a brief contact over a flaky trace is suppressed as a phantom tap") {
        var sim = PadSimulator(grid: grid)
        let map = deadMap(grid: grid, flakyColumns: [11])
        let tracker = ContactTracker(deadMap: map)
        let onFlakyCell = grid.center(of: Cell(col: 11, row: 9))

        var frames = sim.hold(at: onFlakyCell, seconds: 0.03)
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        frames.append(sim.emptyFrame())
        let outputs = run(tracker, frames)

        expectEq(outputs.suppressedTapCount, 1, "this is the spurious click")
        expectEq(outputs.fingerUpCount, 0)
    }

    test("a real tap over healthy area is reported as a tap") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: midStripe())
        let healthy = grid.center(of: Cell(col: 5, row: 9))

        var frames = sim.hold(at: healthy, seconds: 0.09)
        frames.append(sim.liftFrame(at: healthy))
        let outputs = run(tracker, frames)

        expectEq(outputs.suppressedTapCount, 0)
        let taps = outputs.allEvents.count {
            if case .fingerUp(_, _, _, _, let wasTap) = $0 { return wasTap }
            return false
        }
        expectEq(taps, 1)
    }

    test("a long press over a flaky trace is not mistaken for a phantom") {
        var sim = PadSimulator(grid: grid)
        sim.flakyColumns = []
        let tracker = ContactTracker(deadMap: deadMap(grid: grid, flakyColumns: [11]))
        let onFlakyCell = grid.center(of: Cell(col: 11, row: 9))

        var frames = sim.hold(at: onFlakyCell, seconds: 0.4)
        frames.append(sim.liftFrame(at: onFlakyCell))
        let outputs = run(tracker, frames)

        expectEq(outputs.suppressedTapCount, 0,
                 "a deliberate press must survive, however bad the trace")
        expectEq(outputs.fingerUpCount, 1)
    }

    test("two fingers landing in quick succession stay two fingers") {
        let tracker = ContactTracker(deadMap: midStripe())
        var time = 1_000.0
        let interval = 1.0 / 90
        var outputs: [TrackerOutput] = []

        let first = grid.center(of: Cell(col: 9, row: 9))
        let second = grid.center(of: Cell(col: 13, row: 9))

        for _ in 0..<4 {
            outputs.append(tracker.process(TouchFrame(
                timestamp: time,
                samples: [TouchSample(hardwareID: 1, position: first)])))
            time += interval
        }
        for _ in 0..<4 {
            outputs.append(tracker.process(TouchFrame(
                timestamp: time,
                samples: [TouchSample(hardwareID: 1, position: first),
                          TouchSample(hardwareID: 2, position: second)])))
            time += interval
        }

        expectEq(outputs.distinctFingerIDs.count, 2,
                 "re-association must not swallow a genuine second finger")
        expectEq(outputs.last?.fingers.count, 2)
    }

    test("coasting is capped so a flick into a dead stripe cannot fling the cursor") {
        let config = TrackerConfig(maxCoastDistance: 0.1)
        let tracker = ContactTracker(deadMap: midStripe(), config: config)
        var time = 1_000.0
        let interval = 1.0 / 90
        var outputs: [TrackerOutput] = []

        // Fast approach to the stripe, then silence for a long time.
        let onStripe = grid.center(of: Cell(col: 11, row: 9))
        for step in 0..<6 {
            let x = onStripe.x - 0.08 + Double(step) * 0.016
            outputs.append(tracker.process(TouchFrame(
                timestamp: time,
                samples: [TouchSample(hardwareID: 1,
                                      position: Point(x: x, y: 0.5))])))
            time += interval
        }
        let beforeGap = outputs.last!.fingers[0].position
        for _ in 0..<10 {
            outputs.append(tracker.process(TouchFrame(timestamp: time, samples: [])))
            time += interval
        }

        let coasted = outputs.flatMap(\.fingers).filter(\.isCoasting)
        let travelled = coasted.reduce(0) { $0 + $1.delta.magnitude }
        expect(travelled <= 0.1 + 1e-9,
               "coasted \(travelled), cap is 0.1")
        _ = beforeGap
    }

    test("a gap longer than the grace window is a lift and then a new finger") {
        let tracker = ContactTracker(deadMap: midStripe())
        var time = 1_000.0
        let interval = 1.0 / 90
        var outputs: [TrackerOutput] = []
        let onStripe = grid.center(of: Cell(col: 11, row: 9))

        for _ in 0..<5 {
            outputs.append(tracker.process(TouchFrame(
                timestamp: time,
                samples: [TouchSample(hardwareID: 1, position: onStripe)])))
            time += interval
        }
        // Silence for well beyond the 120 ms grace window.
        for _ in 0..<40 {
            outputs.append(tracker.process(TouchFrame(timestamp: time, samples: [])))
            time += interval
        }
        for _ in 0..<5 {
            outputs.append(tracker.process(TouchFrame(
                timestamp: time,
                samples: [TouchSample(hardwareID: 2, position: onStripe)])))
            time += interval
        }

        expectEq(outputs.distinctFingerIDs.count, 2,
                 "half a second apart is two separate touches")
    }

    test("an uncalibrated map still repairs dropouts, just without evidence gating") {
        var sim = PadSimulator(grid: grid)
        sim.deadColumns = [11]
        let tracker = ContactTracker(deadMap: .empty(grid: grid))
        let outputs = run(tracker, sim.sweep(from: Point(x: 0.2, y: 0.5),
                                             to: Point(x: 0.8, y: 0.5),
                                             seconds: 0.4))

        expectEq(outputs.distinctFingerIDs.count, 1,
                 "the tracker should help before calibration too")
        expectEq(outputs.fingerUpCount, 0)
    }

    test("resetting clears all state") {
        var sim = PadSimulator(grid: grid)
        let tracker = ContactTracker(deadMap: midStripe())
        _ = run(tracker, sim.hold(at: Point(x: 0.4, y: 0.5), seconds: 0.1))
        expect(tracker.activeFingerCount > 0)
        tracker.reset()
        expectEq(tracker.activeFingerCount, 0)
    }
  }
}
