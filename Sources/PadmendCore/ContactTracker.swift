import Foundation

public struct TrackerConfig: Codable, Sendable {
    /// How long a contact that vanished without an affirmative lift may be
    /// held open before it is treated as a real lift.
    public var graceWindow: Double
    /// How far, in normalized units, a reappearing contact may be from a
    /// held-open track's predicted position and still be judged the same finger.
    public var adoptRadius: Double
    /// Time constant of the velocity decay applied while coasting.
    public var coastDecayTau: Double
    /// Hard ceiling on how far the pointer may coast on one dropout. Without
    /// this, a fast flick into a dead stripe would fling the cursor away.
    public var maxCoastDistance: Double
    /// How long the stitch offset takes to bleed off after a dropout is
    /// repaired. The cursor is wrong by the coasting error at the moment of
    /// re-acquisition; bleeding it off beats snapping.
    public var stitchDuration: Double
    /// Require dead-map evidence before re-associating a contact across a gap.
    /// Without evidence, two fingers landing in quick succession could be
    /// mistaken for one finger that flickered.
    public var requireSuspectEvidence: Bool
    /// Only hold a vanished contact open, and only coast, when it disappeared
    /// near a cell known to be unreliable. Elsewhere a vanished contact is a
    /// real lift, and waiting out the grace window would add lag to every lift.
    public var suspectCellsOnly: Bool
    /// Longest contact that may still count as a tap.
    public var tapMaxDuration: Double
    /// Longest path a contact may travel and still count as a tap.
    public var tapMaxPathLength: Double
    /// A tap at least this short, over unreliable sensor area, is a phantom.
    public var phantomTapMaxDuration: Double
    /// Gaps longer than this are not used to re-estimate velocity: the
    /// hardware frame interval is ~11 ms, so a longer gap means a dropout and
    /// the pre-gap velocity is the better estimate.
    public var velocitySampleMaxGap: Double

    public init(graceWindow: Double = 0.12,
                adoptRadius: Double = 0.12,
                coastDecayTau: Double = 0.09,
                maxCoastDistance: Double = 0.30,
                stitchDuration: Double = 0.05,
                requireSuspectEvidence: Bool = true,
                suspectCellsOnly: Bool = true,
                tapMaxDuration: Double = 0.25,
                tapMaxPathLength: Double = 0.03,
                phantomTapMaxDuration: Double = 0.08,
                velocitySampleMaxGap: Double = 0.03) {
        self.graceWindow = graceWindow
        self.adoptRadius = adoptRadius
        self.coastDecayTau = coastDecayTau
        self.maxCoastDistance = maxCoastDistance
        self.stitchDuration = stitchDuration
        self.requireSuspectEvidence = requireSuspectEvidence
        self.suspectCellsOnly = suspectCellsOnly
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxPathLength = tapMaxPathLength
        self.phantomTapMaxDuration = phantomTapMaxDuration
        self.velocitySampleMaxGap = velocitySampleMaxGap
    }

    public static let `default` = TrackerConfig()
}

/// A finger as the rest of the engine sees it: a stable identity, a repaired
/// position, and the movement since the previous frame.
public struct Finger: Equatable, Sendable {
    public let id: Int
    /// Repaired position: the hardware position plus any stitch offset still
    /// bleeding off, or the extrapolated position during a dropout.
    public var position: Point
    /// Movement since the previous frame, in normalized units.
    public var delta: Point
    /// True while the hardware is reporting nothing and this position is
    /// extrapolated.
    public var isCoasting: Bool
    public var age: Double
    public var pathLength: Double

    public init(id: Int,
                position: Point,
                delta: Point,
                isCoasting: Bool,
                age: Double,
                pathLength: Double) {
        self.id = id
        self.position = position
        self.delta = delta
        self.isCoasting = isCoasting
        self.age = age
        self.pathLength = pathLength
    }
}

public enum TrackerEvent: Equatable, Sendable {
    case fingerDown(id: Int, at: Point)
    case fingerUp(id: Int, at: Point, duration: Double, pathLength: Double, wasTap: Bool)
    /// A tap that was discarded because it began and ended over unreliable
    /// sensor area in less time than a real tap takes. These are the spurious
    /// clicks a flickering trace produces.
    case phantomTapSuppressed(id: Int, at: Point, duration: Double)
    /// A contact that vanished and came back was recognised as the same
    /// finger, so no lift or land was reported to the rest of the system.
    case dropoutRepaired(id: Int, gap: Double, from: Point, to: Point)
}

public struct TrackerOutput: Equatable, Sendable {
    public var timestamp: Double
    public var fingers: [Finger]
    public var events: [TrackerEvent]

    public init(timestamp: Double, fingers: [Finger], events: [TrackerEvent]) {
        self.timestamp = timestamp
        self.fingers = fingers
        self.events = events
    }
}

/// Turns the raw contact stream into stable fingers.
///
/// This is where a damaged trackpad is made to behave. Three repairs happen
/// here, and they are the reason the project exists:
///
/// 1. **Re-association.** A contact that vanishes over an unreliable cell and
///    reappears nearby is the same finger. Reporting it as a lift followed by
///    a land is what breaks drags and fires stray clicks.
/// 2. **Coasting.** While the hardware says nothing, the finger's last known
///    velocity carries the pointer, decaying, so motion across a dead stripe
///    does not stall mid-gesture.
/// 3. **Phantom tap suppression.** A contact that appears and disappears over
///    unreliable area faster than a human taps is sensor noise, not a click.
///
/// All three are gated on dead-map evidence. On a healthy pad, or before
/// calibration, the tracker stays close to a pass-through.
public final class ContactTracker {
    public var deadMap: DeadMap
    public var config: TrackerConfig

    private struct Track {
        let id: Int
        var hardwareID: Int32
        /// Last position the hardware actually reported.
        var realPosition: Point
        /// Position emitted on the previous frame, used to derive delta.
        var lastEmittedPosition: Point
        /// Position being emitted now: real plus stitch offset, or extrapolated.
        var reportedPosition: Point
        var velocity: Point
        var lastRealTime: Double
        var startTime: Double
        var pathLength: Double
        var stitchOffset: Point
        var stitchStart: Double
        var isCoasting: Bool
        var coastDistance: Double
        var touchedSuspectArea: Bool
    }

    private var tracks: [Track] = []
    private var nextTrackID = 1
    private var lastTimestamp: Double?

    public init(deadMap: DeadMap, config: TrackerConfig = .default) {
        self.deadMap = deadMap
        self.config = config
    }

    public func reset() {
        tracks.removeAll()
        lastTimestamp = nil
    }

    public var activeFingerCount: Int { tracks.count }

    public func process(_ frame: TouchFrame) -> TrackerOutput {
        let now = frame.timestamp
        // Clamped because a stalled callback queue would otherwise produce one
        // enormous extrapolation step.
        let dt = min(max((now - (lastTimestamp ?? now)), 0), 0.1)
        lastTimestamp = now

        var events: [TrackerEvent] = []

        // An affirmative breakTouch is the hardware telling us the finger
        // really left. Honour it immediately and never coast on it.
        for sample in frame.samples where sample.state.isAffirmativeLift {
            if let index = tracks.firstIndex(where: { $0.hardwareID == sample.hardwareID }) {
                var track = tracks[index]
                track.realPosition = sample.position
                events.append(contentsOf: finalize(track, at: sample.position))
                tracks.remove(at: index)
            }
        }

        var matched = Set<Int>()
        for sample in frame.samples where sample.state.isOnSurface {
            if let index = tracks.firstIndex(where: { $0.hardwareID == sample.hardwareID }) {
                applyRealSample(sample, to: &tracks[index], at: now)
                matched.insert(tracks[index].id)
                continue
            }

            if let index = adoptionCandidate(for: sample, at: now, excluding: matched) {
                let gap = now - tracks[index].lastRealTime
                let from = tracks[index].realPosition
                events.append(.dropoutRepaired(id: tracks[index].id, gap: gap,
                                               from: from, to: sample.position))
                tracks[index].hardwareID = sample.hardwareID
                applyRealSample(sample, to: &tracks[index], at: now)
                matched.insert(tracks[index].id)
                continue
            }

            let track = makeTrack(for: sample, at: now)
            tracks.append(track)
            matched.insert(track.id)
            events.append(.fingerDown(id: track.id, at: sample.position))
        }

        // Anything the hardware stopped reporting is either a dropout to be
        // carried, or a lift to be reported.
        var expired: [Int] = []
        for index in tracks.indices where !matched.contains(tracks[index].id) {
            if shouldHoldOpen(tracks[index], at: now) {
                coast(&tracks[index], dt: dt)
            } else {
                events.append(contentsOf: finalize(tracks[index],
                                                   at: tracks[index].realPosition))
                expired.append(index)
            }
        }
        for index in expired.reversed() { tracks.remove(at: index) }

        var fingers: [Finger] = []
        for index in tracks.indices {
            tracks[index].reportedPosition =
                tracks[index].isCoasting
                    ? tracks[index].reportedPosition
                    : tracks[index].realPosition + currentStitchOffset(tracks[index], at: now)

            let finger = Finger(id: tracks[index].id,
                                position: tracks[index].reportedPosition,
                                delta: tracks[index].reportedPosition
                                    - tracks[index].lastEmittedPosition,
                                isCoasting: tracks[index].isCoasting,
                                age: now - tracks[index].startTime,
                                pathLength: tracks[index].pathLength)
            fingers.append(finger)
            tracks[index].lastEmittedPosition = tracks[index].reportedPosition
        }

        return TrackerOutput(timestamp: now, fingers: fingers, events: events)
    }

    // MARK: - Track lifecycle

    private func makeTrack(for sample: TouchSample, at now: Double) -> Track {
        defer { nextTrackID += 1 }
        return Track(id: nextTrackID,
                     hardwareID: sample.hardwareID,
                     realPosition: sample.position,
                     lastEmittedPosition: sample.position,
                     reportedPosition: sample.position,
                     velocity: sample.velocity,
                     lastRealTime: now,
                     startTime: now,
                     pathLength: 0,
                     stitchOffset: .zero,
                     stitchStart: now,
                     isCoasting: false,
                     coastDistance: 0,
                     touchedSuspectArea: deadMap.isNearSuspectCell(sample.position))
    }

    private func applyRealSample(_ sample: TouchSample,
                                 to track: inout Track,
                                 at now: Double) {
        let gap = now - track.lastRealTime

        if track.isCoasting {
            // The pointer has been driven by extrapolation and is now wrong by
            // whatever the extrapolation got wrong. Carry that error as an
            // offset and bleed it off rather than snapping the cursor.
            var offset = track.reportedPosition - sample.position
            if offset.magnitude > config.maxCoastDistance {
                offset = offset * (config.maxCoastDistance / offset.magnitude)
            }
            track.stitchOffset = offset
            track.stitchStart = now
            track.isCoasting = false
            track.coastDistance = 0
        }

        if gap > 0 && gap <= config.velocitySampleMaxGap {
            let observed = (sample.position - track.realPosition) * (1 / gap)
            // Light smoothing: the raw per-frame estimate is noisy enough to
            // make coasting jittery if trusted outright.
            track.velocity = track.velocity * 0.4 + observed * 0.6
        }

        track.pathLength += track.realPosition.distance(to: sample.position)
        track.realPosition = sample.position
        track.lastRealTime = now
        if deadMap.isNearSuspectCell(sample.position) {
            track.touchedSuspectArea = true
        }
    }

    /// True while a vanished contact should be kept alive rather than reported
    /// as a lift.
    private func shouldHoldOpen(_ track: Track, at now: Double) -> Bool {
        guard now - track.lastRealTime <= config.graceWindow else { return false }
        guard config.suspectCellsOnly, deadMap.isCalibrated else { return true }
        return deadMap.isNearSuspectCell(track.realPosition)
    }

    private func coast(_ track: inout Track, dt: Double) {
        if !track.isCoasting {
            track.isCoasting = true
            track.coastDistance = 0
        }
        guard dt > 0 else { return }

        track.velocity = track.velocity * exp(-dt / config.coastDecayTau)
        var step = track.velocity * dt
        let remaining = config.maxCoastDistance - track.coastDistance
        if step.magnitude > remaining {
            step = remaining > 0 ? step * (remaining / step.magnitude) : .zero
            track.velocity = .zero
        }
        track.reportedPosition = track.reportedPosition + step
        track.coastDistance += step.magnitude
    }

    private func currentStitchOffset(_ track: Track, at now: Double) -> Point {
        guard track.stitchOffset != .zero else { return .zero }
        let elapsed = now - track.stitchStart
        guard elapsed < config.stitchDuration else { return .zero }
        let remaining = 1 - (elapsed / config.stitchDuration)
        return track.stitchOffset * remaining
    }

    private func finalize(_ track: Track, at position: Point) -> [TrackerEvent] {
        let duration = max(0, track.lastRealTime - track.startTime)
        let wasTap = duration <= config.tapMaxDuration
            && track.pathLength <= config.tapMaxPathLength

        let isPhantom = wasTap
            && track.touchedSuspectArea
            && duration <= config.phantomTapMaxDuration
        if isPhantom {
            return [.phantomTapSuppressed(id: track.id, at: position, duration: duration)]
        }
        return [.fingerUp(id: track.id, at: position, duration: duration,
                          pathLength: track.pathLength, wasTap: wasTap)]
    }

    // MARK: - Re-association

    private func adoptionCandidate(for sample: TouchSample,
                                   at now: Double,
                                   excluding matched: Set<Int>) -> Int? {
        var best: Int? = nil
        var bestDistance = Double.infinity

        for index in tracks.indices {
            let track = tracks[index]
            if matched.contains(track.id) { continue }

            let gap = now - track.lastRealTime
            guard gap > 0, gap <= config.graceWindow else { continue }

            if config.requireSuspectEvidence, deadMap.isCalibrated {
                let crossesSuspect = deadMap.segmentCrossesSuspectCell(
                    from: track.realPosition, to: sample.position)
                let vanishedOverSuspect = deadMap.isNearSuspectCell(track.realPosition)
                guard crossesSuspect || vanishedOverSuspect else { continue }
            }

            let predicted = track.realPosition + track.velocity * gap
            let distance = min(predicted.distance(to: sample.position),
                               track.realPosition.distance(to: sample.position))
            guard distance <= config.adoptRadius else { continue }

            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }
}
