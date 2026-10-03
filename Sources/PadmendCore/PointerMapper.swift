import Foundation

public struct PointerConfig: Codable, Sendable {
    /// Screen points per millimetre of finger travel before acceleration.
    public var pointsPerMM: Double
    /// Gain at slow speeds, for precision.
    public var minGain: Double
    /// Gain at fast speeds, for reach.
    public var maxGain: Double
    /// Speed, in mm/s, at or below which `minGain` applies.
    public var accelLowSpeed: Double
    /// Speed, in mm/s, at or above which `maxGain` applies.
    public var accelHighSpeed: Double
    /// Whether to scale motion up to compensate for surface lost to dead
    /// traces, so the whole screen stays reachable from the part of the pad
    /// that still works.
    public var compensateForDeadArea: Bool
    /// Ceiling on that compensation. Past roughly 3x the pointer becomes
    /// unusable regardless of how much surface was lost.
    public var maxCompensation: Double
    /// MultitouchSupport reports y increasing away from the user; screen
    /// coordinates increase downward.
    public var invertY: Bool

    public init(pointsPerMM: Double = 6,
                minGain: Double = 0.55,
                maxGain: Double = 2.6,
                accelLowSpeed: Double = 12,
                accelHighSpeed: Double = 220,
                compensateForDeadArea: Bool = true,
                maxCompensation: Double = 3,
                invertY: Bool = true) {
        self.pointsPerMM = pointsPerMM
        self.minGain = minGain
        self.maxGain = maxGain
        self.accelLowSpeed = accelLowSpeed
        self.accelHighSpeed = accelHighSpeed
        self.compensateForDeadArea = compensateForDeadArea
        self.maxCompensation = maxCompensation
        self.invertY = invertY
    }

    public static let `default` = PointerConfig()
}

/// Turns finger movement into pointer movement.
///
/// Two jobs. The acceleration curve is ordinary: slow motion is geared down
/// for precision, fast motion geared up for reach. The compensation is the
/// point of this project — when a severed trace removes a fifth of the pad's
/// width, horizontal motion is scaled up by the reciprocal of what is left, so
/// the far edge of the screen is still reachable from the part of the surface
/// that still answers.
///
/// Sub-pixel movement is accumulated rather than discarded, because at low
/// gain a slow finger produces less than one point per frame and rounding each
/// frame independently would simply drop that motion on the floor.
public struct PointerMapper {
    public var config: PointerConfig
    public var deadMap: DeadMap

    private var residual: Point = .zero

    public init(deadMap: DeadMap, config: PointerConfig = .default) {
        self.deadMap = deadMap
        self.config = config
    }

    /// Horizontal and vertical compensation factors implied by the dead map.
    public var compensation: Point {
        guard config.compensateForDeadArea else { return Point(x: 1, y: 1) }
        let width = deadMap.usableWidthFraction
        let height = deadMap.usableHeightFraction
        return Point(
            x: min(config.maxCompensation, width > 0 ? 1 / width : 1),
            y: min(config.maxCompensation, height > 0 ? 1 / height : 1))
    }

    /// Whole-point pointer movement for one frame, in screen convention.
    public mutating func step(delta: Point, dt: Double) -> (dx: Int, dy: Int) {
        let movement = pointMovement(delta: delta, dt: dt)
        residual = residual + movement

        let dx = residual.x < 0 ? -Int(-residual.x) : Int(residual.x)
        let dy = residual.y < 0 ? -Int(-residual.y) : Int(residual.y)
        residual = Point(x: residual.x - Double(dx), y: residual.y - Double(dy))
        return (dx, dy)
    }

    /// Fractional pointer movement for one frame, before accumulation.
    /// Exposed so the gain curve can be tested directly.
    public func pointMovement(delta: Point, dt: Double) -> Point {
        let factors = compensation
        let compensated = Point(x: delta.x * factors.x, y: delta.y * factors.y)
        let mm = deadMap.grid.millimetres(compensated)

        let speed = dt > 0 ? mm.magnitude / dt : 0
        let gain = accelerationGain(forSpeed: speed)

        let scale = config.pointsPerMM * gain
        return Point(x: mm.x * scale,
                     y: mm.y * scale * (config.invertY ? -1 : 1))
    }

    public func accelerationGain(forSpeed speed: Double) -> Double {
        let low = config.accelLowSpeed
        let high = max(config.accelHighSpeed, low + .ulpOfOne)
        let t = min(max((speed - low) / (high - low), 0), 1)
        let eased = t * t * (3 - 2 * t)
        return config.minGain + (config.maxGain - config.minGain) * eased
    }

    /// Drops accumulated sub-pixel movement. Called when all fingers lift, so
    /// a new gesture does not inherit a fraction of the last one.
    public mutating func flushResidual() {
        residual = .zero
    }
}
