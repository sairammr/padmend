import Foundation

extension TrackerConfig {
    /// Settings used while calibrating.
    ///
    /// Evidence gating is off because there is no map yet to gate on, and the
    /// adoption window is wider: a severed trace is one column, but a wider
    /// patch of damage needs a longer reach before the tracker will accept
    /// that the finger on the far side is the same finger. Getting that wrong
    /// during calibration only costs a missed transit; getting it wrong during
    /// normal use would merge two fingers, which is why the live defaults are
    /// tighter.
    public static let calibration = TrackerConfig(
        graceWindow: 0.30,
        adoptRadius: 0.30,
        requireSuspectEvidence: false,
        suspectCellsOnly: false)
}

/// Drives calibration: feed it the raw frames and the tracker's view of them,
/// and it accumulates the evidence a dead map is classified from.
///
/// It needs both. Hits come from the raw samples, because only the hardware
/// can say where it did report a touch. Transits come from the tracker, because
/// only re-association can say that the finger which reappeared on the far side
/// of a gap is the same finger that went in — which is the whole basis for
/// claiming the cells in between are dead rather than unvisited.
public final class Calibrator {
    public private(set) var coverage: CoverageMap
    public private(set) var repairedDropouts = 0
    public private(set) var frameCount = 0

    /// How many frames each contact currently in a dropout has gone unreported.
    ///
    /// Held rather than banked immediately, because a contact that vanishes
    /// and comes back was a sensor failure while one that vanishes and stays
    /// gone was a finger lift. Crediting the latter would paint a dead spot
    /// wherever the user happens to lift. Which it was is only known in
    /// retrospect, so the evidence waits.
    private var silentFrameCounts: [Int: Int] = [:]

    public init(grid: SensorGrid) {
        self.coverage = CoverageMap(grid: grid)
    }

    public func ingest(frame: TouchFrame, output: TrackerOutput) {
        frameCount += 1

        for sample in frame.samples where sample.state.isOnSurface {
            coverage.recordHit(at: sample.position)
        }

        for finger in output.fingers where finger.isCoasting {
            silentFrameCounts[finger.id, default: 0] += 1
        }

        for event in output.events {
            switch event {
            case .dropoutRepaired(let id, _, let from, let to):
                // Confirmed sensor failure. Spread the silent frames evenly
                // along the straight line between the last real sample and the
                // first one after the gap.
                //
                // The tracker's own extrapolated positions are not used here:
                // its velocity decays during a dropout, so across a wide dead
                // region the coasted positions lag the real finger and pile all
                // the blame on the near edge, leaving the far side of the
                // damage undetected. Once the far endpoint is known, even
                // interpolation is the better estimate.
                let frames = max(1, silentFrameCounts.removeValue(forKey: id) ?? 1)
                for index in 0..<frames {
                    let t = (Double(index) + 0.5) / Double(frames)
                    coverage.recordSilentFrame(at: from + (to - from) * t)
                }
                repairedDropouts += 1
            case .fingerUp(let id, _, _, _, _),
                 .phantomTapSuppressed(let id, _, _):
                // The finger really left; those frames prove nothing.
                silentFrameCounts.removeValue(forKey: id)
            case .fingerDown:
                break
            }
        }
    }

    public func makeDeadMap(thresholds: DeadMapThresholds = .default) -> DeadMap {
        DeadMap.classify(coverage, thresholds: thresholds)
    }

    public func reset() {
        coverage.reset()
        repairedDropouts = 0
        frameCount = 0
        silentFrameCounts.removeAll()
    }

    /// Fraction of the pad with any evidence yet, for a progress readout.
    public var progress: Double { coverage.evidenceCoverage }

    /// Cells with no evidence at all, so the UI can tell the user where to
    /// keep sweeping instead of making them guess.
    public func unexploredCells() -> [Cell] {
        (0..<coverage.grid.cellCount).compactMap { index in
            let cell = coverage.grid.cell(atIndex: index)
            let unexplored = coverage.hits(at: cell) == 0
                && coverage.transits(at: cell) == 0
            return unexplored ? cell : nil
        }
    }
}
