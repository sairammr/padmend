import Foundation

public enum GesturePhase: Equatable, Sendable {
    case began
    case changed
    case ended
    /// Scrolling continues under its own inertia after the fingers lift.
    case momentumBegan
    case momentumChanged
    case momentumEnded
}

public enum SwipeDirection: Equatable, Sendable {
    case left, right, up, down
}

public enum GestureEvent: Equatable, Sendable {
    /// Scroll movement in screen points.
    case scroll(phase: GesturePhase, dx: Int, dy: Int)
    /// Pinch, as a relative change in separation: +0.1 means ten percent
    /// further apart since the previous frame.
    case pinch(phase: GesturePhase, magnification: Double)
    /// A three- or four-finger swipe, reported once per gesture.
    case swipe(fingers: Int, direction: SwipeDirection)
}

public struct GestureConfig: Codable, Sendable {
    /// Screen points per millimetre of two-finger travel.
    public var scrollPointsPerMM: Double
    /// Finger movement follows content rather than the scrollbar.
    public var naturalScrolling: Bool
    /// Movement required before a two-finger gesture commits to being a
    /// scroll or a pinch.
    public var startThresholdMM: Double
    /// How much separation change must exceed translation before the gesture
    /// is read as a pinch rather than a scroll.
    public var pinchBias: Double
    /// Centroid travel required for a three- or four-finger swipe.
    public var swipeThresholdMM: Double
    /// Time constant of post-lift scroll inertia.
    public var momentumDecayTau: Double
    /// Speed below which inertia stops, in millimetres per second.
    public var momentumCutoffSpeed: Double
    /// Hard ceiling on inertia duration.
    public var momentumMaxDuration: Double

    public init(scrollPointsPerMM: Double = 4.2,
                naturalScrolling: Bool = true,
                startThresholdMM: Double = 1.2,
                pinchBias: Double = 1.2,
                swipeThresholdMM: Double = 9,
                momentumDecayTau: Double = 0.32,
                momentumCutoffSpeed: Double = 18,
                momentumMaxDuration: Double = 1.6) {
        self.scrollPointsPerMM = scrollPointsPerMM
        self.naturalScrolling = naturalScrolling
        self.startThresholdMM = startThresholdMM
        self.pinchBias = pinchBias
        self.swipeThresholdMM = swipeThresholdMM
        self.momentumDecayTau = momentumDecayTau
        self.momentumCutoffSpeed = momentumCutoffSpeed
        self.momentumMaxDuration = momentumMaxDuration
    }

    public static let `default` = GestureConfig()
}

/// Interprets everything that is not a single moving finger.
///
/// Two fingers are ambiguous: the same contacts can mean scroll or pinch, and
/// the only honest way to tell is to watch which quantity moves first. So the
/// gesture stays undecided until the fingers have travelled far enough to
/// commit, then latches — switching mode mid-gesture would make both feel
/// unreliable. Three and four finger swipes are reported once and then latched
/// for the same reason.
///
/// Scroll inertia is generated here because macOS produces it in the trackpad
/// driver, below the level this program works at. Taking over the pad means
/// taking over the feel of it too.
public struct GestureRecognizer {
    public var config: GestureConfig
    public let grid: SensorGrid

    private enum Mode: Equatable {
        case idle
        /// Two fingers down, not yet committed to scroll or pinch.
        case deciding
        case scrolling
        case pinching
        /// A swipe already reported; waiting for the fingers to lift.
        case swiped
    }

    private var mode: Mode = .idle
    private var fingerCount = 0

    private var lastCentroid: Point = .zero
    private var lastSpread: Double = 0
    private var referenceSpread: Double = 0
    private var translationTravel: Double = 0
    private var separationTravel: Double = 0
    /// Movement accumulated while the gesture was undecided, emitted with the
    /// `began` event so a scroll does not start with a dead patch.
    private var pendingTranslation: Point = .zero
    private var swipeTravel: Point = .zero

    /// Scroll velocity in screen points per second, for inertia.
    private var scrollVelocity: Point = .zero
    private var momentumElapsed: Double = 0
    private var momentumActive = false
    private var residual: Point = .zero

    public init(grid: SensorGrid, config: GestureConfig = .default) {
        self.grid = grid
        self.config = config
    }

    public var isMomentumActive: Bool { momentumActive }

    /// Feeds one frame of tracked fingers and returns whatever gestures that
    /// implies.
    public mutating func update(fingers: [Finger], dt: Double) -> [GestureEvent] {
        var events: [GestureEvent] = []

        if fingers.count != fingerCount {
            events.append(contentsOf: endCurrentGesture())
            fingerCount = fingers.count
            beginTracking(fingers)
        }

        guard dt > 0 else { return events }

        switch fingers.count {
        case 2:
            events.append(contentsOf: updateTwoFinger(fingers, dt: dt))
        case 3, 4:
            events.append(contentsOf: updateSwipe(fingers))
        default:
            break
        }
        return events
    }

    /// Advances scroll inertia. Driven by a timer rather than the contact
    /// stream, because the hardware stops reporting once the fingers are gone.
    public mutating func tick(dt: Double) -> [GestureEvent] {
        guard momentumActive, dt > 0 else { return [] }

        momentumElapsed += dt
        scrollVelocity = scrollVelocity * exp(-dt / config.momentumDecayTau)

        let speedMM = (scrollVelocity.magnitude / config.scrollPointsPerMM)
        let expired = momentumElapsed >= config.momentumMaxDuration
            || speedMM <= config.momentumCutoffSpeed
        if expired {
            momentumActive = false
            residual = .zero
            return [.scroll(phase: .momentumEnded, dx: 0, dy: 0)]
        }

        let step = quantize(scrollVelocity * dt)
        guard step.dx != 0 || step.dy != 0 else { return [] }
        return [.scroll(phase: .momentumChanged, dx: step.dx, dy: step.dy)]
    }

    public mutating func reset() {
        mode = .idle
        fingerCount = 0
        momentumActive = false
        scrollVelocity = .zero
        residual = .zero
    }

    // MARK: - Two fingers

    private mutating func updateTwoFinger(_ fingers: [Finger],
                                          dt: Double) -> [GestureEvent] {
        let centroid = centre(of: fingers)
        let spread = separation(of: fingers)

        let translation = centroid - lastCentroid
        let translationMM = grid.millimetresSafe(translation)
        let separationMM = abs(spread - lastSpread) * grid.widthMM
        defer {
            lastCentroid = centroid
            lastSpread = spread
        }

        switch mode {
        case .deciding:
            translationTravel += translationMM.magnitude
            separationTravel += separationMM
            pendingTranslation = pendingTranslation + translation
            guard max(translationTravel, separationTravel)
                    >= config.startThresholdMM else { return [] }

            if separationTravel > translationTravel * config.pinchBias {
                mode = .pinching
                pendingTranslation = .zero
                return [.pinch(phase: .began, magnification: 0)]
            }
            mode = .scrolling
            // The movement spent deciding is real movement, so it is carried
            // into the first event rather than discarded.
            let step = scrollStep(from: pendingTranslation, dt: dt)
            pendingTranslation = .zero
            return [.scroll(phase: .began, dx: step.dx, dy: step.dy)]

        case .scrolling:
            let step = scrollStep(from: translation, dt: dt)
            guard step.dx != 0 || step.dy != 0 else { return [] }
            return [.scroll(phase: .changed, dx: step.dx, dy: step.dy)]

        case .pinching:
            guard referenceSpread > 0 else { return [] }
            let magnification = (spread - lastSpread) / referenceSpread
            guard magnification != 0 else { return [] }
            return [.pinch(phase: .changed, magnification: magnification)]

        default:
            return []
        }
    }

    private mutating func scrollStep(from delta: Point,
                                     dt: Double) -> (dx: Int, dy: Int) {
        let mm = grid.millimetresSafe(delta)
        let sign: Double = config.naturalScrolling ? 1 : -1
        let points = Point(x: mm.x * config.scrollPointsPerMM * sign,
                           y: mm.y * config.scrollPointsPerMM * sign)
        scrollVelocity = points * (1 / dt)
        return quantize(points)
    }

    // MARK: - Swipes

    private mutating func updateSwipe(_ fingers: [Finger]) -> [GestureEvent] {
        guard mode == .deciding || mode == .idle else { return [] }

        let centroid = centre(of: fingers)
        swipeTravel = swipeTravel + (centroid - lastCentroid)
        lastCentroid = centroid

        let travelMM = grid.millimetres(swipeTravel)
        guard travelMM.magnitude >= config.swipeThresholdMM else { return [] }

        // All fingers must agree, or a pinch with a drifting centroid would
        // register as a swipe.
        let horizontal = abs(travelMM.x) >= abs(travelMM.y)
        let coherent = fingers.allSatisfy { finger in
            horizontal
                ? finger.delta.x * swipeTravel.x >= 0
                : finger.delta.y * swipeTravel.y >= 0
        }
        guard coherent else { return [] }

        mode = .swiped
        let direction: SwipeDirection
        if horizontal {
            direction = travelMM.x > 0 ? .right : .left
        } else {
            // Finger y grows away from the user, which is up the screen.
            direction = travelMM.y > 0 ? .up : .down
        }
        return [.swipe(fingers: fingers.count, direction: direction)]
    }

    // MARK: - Lifecycle

    private mutating func beginTracking(_ fingers: [Finger]) {
        translationTravel = 0
        separationTravel = 0
        pendingTranslation = .zero
        swipeTravel = .zero
        lastCentroid = fingers.isEmpty ? .zero : centre(of: fingers)
        lastSpread = separation(of: fingers)
        referenceSpread = lastSpread
        mode = fingers.count >= 2 ? .deciding : .idle
    }

    private mutating func endCurrentGesture() -> [GestureEvent] {
        defer { mode = .idle }
        switch mode {
        case .scrolling:
            var events: [GestureEvent] = [.scroll(phase: .ended, dx: 0, dy: 0)]
            let speedMM = scrollVelocity.magnitude / config.scrollPointsPerMM
            if speedMM > config.momentumCutoffSpeed {
                momentumActive = true
                momentumElapsed = 0
                events.append(.scroll(phase: .momentumBegan, dx: 0, dy: 0))
            } else {
                scrollVelocity = .zero
            }
            return events
        case .pinching:
            return [.pinch(phase: .ended, magnification: 0)]
        default:
            return []
        }
    }

    // MARK: - Helpers

    private func centre(of fingers: [Finger]) -> Point {
        guard !fingers.isEmpty else { return .zero }
        let sum = fingers.reduce(Point.zero) { $0 + $1.position }
        return sum * (1 / Double(fingers.count))
    }

    /// Mean distance of the fingers from their centroid, in normalized units.
    private func separation(of fingers: [Finger]) -> Double {
        guard fingers.count >= 2 else { return 0 }
        let middle = centre(of: fingers)
        return fingers.reduce(0) { $0 + $1.position.distance(to: middle) }
            / Double(fingers.count)
    }

    private mutating func quantize(_ points: Point) -> (dx: Int, dy: Int) {
        residual = residual + points
        let dx = residual.x < 0 ? -Int(-residual.x) : Int(residual.x)
        let dy = residual.y < 0 ? -Int(-residual.y) : Int(residual.y)
        residual = Point(x: residual.x - Double(dx), y: residual.y - Double(dy))
        return (dx, dy)
    }
}

extension SensorGrid {
    /// Guards against a zero-sized surface, which the private API does
    /// occasionally report before the device is fully up.
    @usableFromInline
    func millimetresSafe(_ delta: Point) -> Point {
        guard widthMM > 0, heightMM > 0 else {
            return SensorGrid.appleBuiltInDefault.millimetres(delta)
        }
        return millimetres(delta)
    }
}
