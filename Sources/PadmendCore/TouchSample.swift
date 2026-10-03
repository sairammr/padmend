import Foundation

/// The lifecycle value MultitouchSupport reports per contact.
///
/// Only `makeTouch` and `touching` mean "finger is on the glass". The useful
/// property for this project is that `breakTouch` is an *affirmative* lift:
/// when the hardware is confident the finger left, it says so. A contact that
/// vanishes from the frame without ever reporting `breakTouch` is the
/// signature of a sensor dropout, which is exactly what we want to repair.
public enum TouchState: Int32, Codable, Sendable {
    case notTracking = 0
    case startInRange = 1
    case hoverInRange = 2
    case makeTouch = 3
    case touching = 4
    case breakTouch = 5
    case lingerInRange = 6
    case outOfRange = 7

    public var isOnSurface: Bool { self == .makeTouch || self == .touching }
    public var isAffirmativeLift: Bool { self == .breakTouch }
}

/// One contact in one hardware frame, decoupled from the C struct so the whole
/// engine can be driven from synthetic data in tests.
public struct TouchSample: Equatable, Sendable {
    public var hardwareID: Int32
    public var state: TouchState
    public var position: Point
    /// Hardware-reported velocity, in normalized units per second.
    public var velocity: Point
    public var size: Double

    public init(hardwareID: Int32,
                state: TouchState = .touching,
                position: Point,
                velocity: Point = .zero,
                size: Double = 1) {
        self.hardwareID = hardwareID
        self.state = state
        self.position = position
        self.velocity = velocity
        self.size = size
    }
}

/// One hardware frame.
public struct TouchFrame: Equatable, Sendable {
    public var timestamp: Double
    public var samples: [TouchSample]

    public init(timestamp: Double, samples: [TouchSample]) {
        self.timestamp = timestamp
        self.samples = samples
    }
}
