import Foundation
import PadmendCore

func runGestureRecognizerTests() {
  suite("Gesture recognition") {
    let grid = SensorGrid.appleBuiltInDefault
    let dt = 1.0 / 90

    /// Builds tracked fingers at the given positions, with deltas relative to
    /// the previous set, the way the tracker reports them.
    func fingers(_ positions: [Point], previous: [Point]? = nil) -> [Finger] {
        positions.enumerated().map { index, position in
            let before = previous?[index] ?? position
            return Finger(id: index + 1,
                          position: position,
                          delta: position - before,
                          isCoasting: false,
                          age: 0.1,
                          pathLength: 0.1)
        }
    }

    /// Drives a gesture by moving every finger along the same offset per frame.
    func drive(_ recognizer: inout GestureRecognizer,
               start: [Point],
               perFrame: Point,
               frames: Int) -> [GestureEvent] {
        var events: [GestureEvent] = []
        var current = start
        events += recognizer.update(fingers: fingers(current), dt: dt)
        for _ in 0..<frames {
            let next = current.map { $0 + perFrame }
            events += recognizer.update(fingers: fingers(next, previous: current),
                                        dt: dt)
            current = next
        }
        return events
    }

    func scrollPhases(_ events: [GestureEvent]) -> [GesturePhase] {
        events.compactMap {
            if case .scroll(let phase, _, _) = $0 { return phase } else { return nil }
        }
    }

    func scrollTotal(_ events: [GestureEvent]) -> (dx: Int, dy: Int) {
        events.reduce(into: (dx: 0, dy: 0)) { total, event in
            if case .scroll(_, let dx, let dy) = event {
                total.dx += dx
                total.dy += dy
            }
        }
    }

    test("two fingers moving together scroll") {
        var recognizer = GestureRecognizer(grid: grid)
        let events = drive(&recognizer,
                           start: [Point(x: 0.4, y: 0.4), Point(x: 0.5, y: 0.4)],
                           perFrame: Point(x: 0, y: 0.01),
                           frames: 20)
        let phases = scrollPhases(events)
        expect(phases.first == .began, "got \(phases.prefix(3))")
        expect(phases.contains(.changed))
        expect(!events.contains { if case .pinch = $0 { return true } else { return false } },
               "straight two-finger movement is not a pinch")
    }

    test("scroll direction follows the fingers, and the flag inverts it") {
        var natural = GestureRecognizer(grid: grid)
        let up = scrollTotal(drive(&natural,
                                   start: [Point(x: 0.4, y: 0.3), Point(x: 0.5, y: 0.3)],
                                   perFrame: Point(x: 0, y: 0.01), frames: 20))

        var inverted = GestureConfig()
        inverted.naturalScrolling = false
        var reversed = GestureRecognizer(grid: grid, config: inverted)
        let down = scrollTotal(drive(&reversed,
                                     start: [Point(x: 0.4, y: 0.3), Point(x: 0.5, y: 0.3)],
                                     perFrame: Point(x: 0, y: 0.01), frames: 20))

        expect(up.dy != 0 && down.dy != 0)
        expect(up.dy * down.dy < 0, "the flag should flip the sign: \(up.dy) vs \(down.dy)")
    }

    test("no scroll is emitted before the start threshold is passed") {
        var recognizer = GestureRecognizer(grid: grid)
        // A single frame of sub-millimetre movement.
        let events = drive(&recognizer,
                           start: [Point(x: 0.4, y: 0.4), Point(x: 0.5, y: 0.4)],
                           perFrame: Point(x: 0, y: 0.0005),
                           frames: 2)
        expect(scrollPhases(events).isEmpty, "got \(scrollPhases(events))")
    }

    test("movement spent deciding is carried into the first scroll event") {
        var recognizer = GestureRecognizer(grid: grid)
        // Creep up on the threshold so several frames accumulate first: each
        // frame is 0.148 mm of travel against a 1.2 mm threshold.
        let perFrame = Point(x: 0, y: 0.002)
        let events = drive(&recognizer,
                           start: [Point(x: 0.4, y: 0.4), Point(x: 0.5, y: 0.4)],
                           perFrame: perFrame,
                           frames: 14)
        guard case .scroll(.began, _, let dy)? = events.first(where: {
            if case .scroll(.began, _, _) = $0 { return true } else { return false }
        }) else {
            expect(false, "no scroll began")
            return
        }
        let oneFrame = abs(perFrame.y) * grid.heightMM * GestureConfig().scrollPointsPerMM
        expect(Double(abs(dy)) > oneFrame,
               "began carried \(dy) points, one frame alone would be \(oneFrame)")
    }

    test("two fingers separating pinch rather than scroll") {
        var recognizer = GestureRecognizer(grid: grid)
        var events: [GestureEvent] = []
        var left = Point(x: 0.45, y: 0.5)
        var right = Point(x: 0.55, y: 0.5)
        events += recognizer.update(fingers: fingers([left, right]), dt: dt)
        for _ in 0..<20 {
            let nextLeft = left + Point(x: -0.004, y: 0)
            let nextRight = right + Point(x: 0.004, y: 0)
            events += recognizer.update(
                fingers: fingers([nextLeft, nextRight], previous: [left, right]),
                dt: dt)
            left = nextLeft
            right = nextRight
        }

        let magnifications = events.compactMap { event -> Double? in
            if case .pinch(_, let magnification) = event { return magnification }
            return nil
        }
        expect(!magnifications.isEmpty, "no pinch recognised")
        expect(magnifications.contains { $0 > 0 }, "separating should magnify")
        expect(scrollPhases(events).isEmpty, "a pinch must not also scroll")
    }

    test("two fingers closing pinch inward") {
        var recognizer = GestureRecognizer(grid: grid)
        var events: [GestureEvent] = []
        var left = Point(x: 0.35, y: 0.5)
        var right = Point(x: 0.65, y: 0.5)
        events += recognizer.update(fingers: fingers([left, right]), dt: dt)
        for _ in 0..<20 {
            let nextLeft = left + Point(x: 0.004, y: 0)
            let nextRight = right + Point(x: -0.004, y: 0)
            events += recognizer.update(
                fingers: fingers([nextLeft, nextRight], previous: [left, right]),
                dt: dt)
            left = nextLeft
            right = nextRight
        }
        let magnifications = events.compactMap { event -> Double? in
            if case .pinch(_, let magnification) = event { return magnification }
            return nil
        }
        expect(magnifications.contains { $0 < 0 }, "closing should demagnify")
    }

    test("a committed gesture does not switch mode midway") {
        var recognizer = GestureRecognizer(grid: grid)
        var events: [GestureEvent] = []
        var left = Point(x: 0.4, y: 0.4)
        var right = Point(x: 0.5, y: 0.4)
        // Commit to a scroll first.
        events += recognizer.update(fingers: fingers([left, right]), dt: dt)
        for _ in 0..<10 {
            let nextLeft = left + Point(x: 0, y: 0.008)
            let nextRight = right + Point(x: 0, y: 0.008)
            events += recognizer.update(
                fingers: fingers([nextLeft, nextRight], previous: [left, right]), dt: dt)
            left = nextLeft
            right = nextRight
        }
        // Then start separating hard, without lifting.
        for _ in 0..<20 {
            let nextLeft = left + Point(x: -0.006, y: 0)
            let nextRight = right + Point(x: 0.006, y: 0)
            events += recognizer.update(
                fingers: fingers([nextLeft, nextRight], previous: [left, right]), dt: dt)
            left = nextLeft
            right = nextRight
        }
        expect(!events.contains { if case .pinch = $0 { return true } else { return false } },
               "a scroll in progress must stay a scroll")
    }

    test("three fingers swiping left report one swipe") {
        var recognizer = GestureRecognizer(grid: grid)
        let events = drive(&recognizer,
                           start: [Point(x: 0.6, y: 0.5), Point(x: 0.65, y: 0.5),
                                   Point(x: 0.7, y: 0.5)],
                           perFrame: Point(x: -0.01, y: 0),
                           frames: 25)
        let swipes = events.compactMap { event -> (Int, SwipeDirection)? in
            if case .swipe(let count, let direction) = event { return (count, direction) }
            return nil
        }
        expectEq(swipes.count, 1, "a swipe must be reported once, not per frame")
        expectEq(swipes.first?.0, 3)
        expectEq(swipes.first?.1, .left)
    }

    test("four fingers swiping up report four, not three") {
        var recognizer = GestureRecognizer(grid: grid)
        let events = drive(&recognizer,
                           start: [Point(x: 0.4, y: 0.3), Point(x: 0.45, y: 0.3),
                                   Point(x: 0.5, y: 0.3), Point(x: 0.55, y: 0.3)],
                           perFrame: Point(x: 0, y: 0.01),
                           frames: 25)
        let swipes = events.compactMap { event -> (Int, SwipeDirection)? in
            if case .swipe(let count, let direction) = event { return (count, direction) }
            return nil
        }
        expectEq(swipes.count, 1)
        expectEq(swipes.first?.0, 4)
        expectEq(swipes.first?.1, .up, "finger y grows away from the user, which is up")
    }

    test("three fingers moving incoherently do not swipe") {
        var recognizer = GestureRecognizer(grid: grid)
        var events: [GestureEvent] = []
        var positions = [Point(x: 0.4, y: 0.5), Point(x: 0.5, y: 0.5),
                         Point(x: 0.6, y: 0.5)]
        events += recognizer.update(fingers: fingers(positions), dt: dt)
        for _ in 0..<30 {
            // Outer fingers spread, middle finger drags the centroid sideways.
            let next = [positions[0] + Point(x: -0.004, y: 0),
                        positions[1] + Point(x: 0.012, y: 0),
                        positions[2] + Point(x: 0.004, y: 0)]
            events += recognizer.update(fingers: fingers(next, previous: positions),
                                        dt: dt)
            positions = next
        }
        let swipes = events.filter {
            if case .swipe = $0 { return true } else { return false }
        }
        expect(swipes.isEmpty, "fingers must agree before this counts as a swipe")
    }

    test("a swipe below the travel threshold is not reported") {
        var recognizer = GestureRecognizer(grid: grid)
        let events = drive(&recognizer,
                           start: [Point(x: 0.5, y: 0.5), Point(x: 0.55, y: 0.5),
                                   Point(x: 0.6, y: 0.5)],
                           perFrame: Point(x: -0.002, y: 0),
                           frames: 5)
        expect(!events.contains { if case .swipe = $0 { return true } else { return false } })
    }

    test("lifting after a fast scroll starts inertia that then stops") {
        var recognizer = GestureRecognizer(grid: grid)
        _ = drive(&recognizer,
                  start: [Point(x: 0.4, y: 0.2), Point(x: 0.5, y: 0.2)],
                  perFrame: Point(x: 0, y: 0.012),
                  frames: 30)

        let onLift = recognizer.update(fingers: [], dt: dt)
        expect(scrollPhases(onLift).contains(.ended))
        expect(scrollPhases(onLift).contains(.momentumBegan),
               "a fast flick should coast")
        expect(recognizer.isMomentumActive)

        var ticks = 0
        var sawChange = false
        var sawEnd = false
        while recognizer.isMomentumActive, ticks < 400 {
            for event in recognizer.tick(dt: dt) {
                if case .scroll(.momentumChanged, _, _) = event { sawChange = true }
                if case .scroll(.momentumEnded, _, _) = event { sawEnd = true }
            }
            ticks += 1
        }
        expect(sawChange, "inertia produced no movement")
        expect(sawEnd, "inertia never ended")
        expect(!recognizer.isMomentumActive)
        expect(ticks < 400, "inertia ran for \(ticks) frames without stopping")
    }

    test("lifting after a slow scroll starts no inertia") {
        var recognizer = GestureRecognizer(grid: grid)
        _ = drive(&recognizer,
                  start: [Point(x: 0.4, y: 0.4), Point(x: 0.5, y: 0.4)],
                  perFrame: Point(x: 0, y: 0.0012),
                  frames: 40)
        let onLift = recognizer.update(fingers: [], dt: dt)
        expect(!scrollPhases(onLift).contains(.momentumBegan))
        expect(!recognizer.isMomentumActive)
    }

    test("inertia does nothing when no scroll preceded it") {
        var recognizer = GestureRecognizer(grid: grid)
        expect(recognizer.tick(dt: dt).isEmpty)
    }

    test("a pinch ends cleanly when the fingers lift") {
        var recognizer = GestureRecognizer(grid: grid)
        var events: [GestureEvent] = []
        var left = Point(x: 0.45, y: 0.5)
        var right = Point(x: 0.55, y: 0.5)
        events += recognizer.update(fingers: fingers([left, right]), dt: dt)
        for _ in 0..<20 {
            let nextLeft = left + Point(x: -0.004, y: 0)
            let nextRight = right + Point(x: 0.004, y: 0)
            events += recognizer.update(
                fingers: fingers([nextLeft, nextRight], previous: [left, right]), dt: dt)
            left = nextLeft
            right = nextRight
        }
        events += recognizer.update(fingers: [], dt: dt)
        let phases = events.compactMap { event -> GesturePhase? in
            if case .pinch(let phase, _) = event { return phase } else { return nil }
        }
        expectEq(phases.first, .began)
        expectEq(phases.last, .ended)
    }

    test("a single finger produces no gesture at all") {
        var recognizer = GestureRecognizer(grid: grid)
        let events = drive(&recognizer,
                           start: [Point(x: 0.3, y: 0.5)],
                           perFrame: Point(x: 0.01, y: 0.01),
                           frames: 30)
        expect(events.isEmpty, "one finger is the pointer's business, not a gesture")
    }

    test("resetting clears inertia and mode") {
        var recognizer = GestureRecognizer(grid: grid)
        _ = drive(&recognizer,
                  start: [Point(x: 0.4, y: 0.2), Point(x: 0.5, y: 0.2)],
                  perFrame: Point(x: 0, y: 0.012),
                  frames: 30)
        _ = recognizer.update(fingers: [], dt: dt)
        expect(recognizer.isMomentumActive)
        recognizer.reset()
        expect(!recognizer.isMomentumActive)
        expect(recognizer.tick(dt: dt).isEmpty)
    }
  }
}
