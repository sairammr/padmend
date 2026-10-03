import Foundation
import PadmendCore

/// Renders the sensor grid in the terminal.
///
/// The map is drawn rather than described because a dead trace is a shape, and
/// the shape is the thing the user needs to recognise — both to trust the
/// result and to see where they have not swept yet.
public enum Terminal {
    public static let clear = "\u{1B}[2J\u{1B}[H"
    public static let home = "\u{1B}[H"
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"

    private static func paint(_ text: String, _ code: String) -> String {
        "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// The pad drawn from live calibration evidence, with the fingers on it.
    public static func render(coverage: CoverageMap,
                              fingers: [Point] = []) -> String {
        let grid = coverage.grid
        let fingerCells = Set(fingers.map { grid.cell(at: $0) })
        var lines: [String] = []

        // Row 0 is nearest the user, so the grid is drawn bottom-up to match
        // the pad in front of them.
        for row in (0..<grid.rows).reversed() {
            var line = "  "
            for col in 0..<grid.cols {
                let cell = Cell(col: col, row: row)
                if fingerCells.contains(cell) {
                    line += paint("@@", "1;36")
                    continue
                }
                let hits = coverage.hits(at: cell)
                let transits = coverage.transits(at: cell)
                switch (hits, transits) {
                case (0, 0):
                    line += paint("··", "90")
                case (0, _):
                    line += paint("XX", "31")
                case (_, 0):
                    line += paint("██", "32")
                default:
                    line += paint("▒▒", "33")
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A classified map.
    public static func render(deadMap map: DeadMap) -> String {
        let grid = map.grid
        var lines: [String] = []
        for row in (0..<grid.rows).reversed() {
            var line = "  "
            for col in 0..<grid.cols {
                switch map.health(at: Cell(col: col, row: row)) {
                case .live: line += paint("██", "32")
                case .flaky: line += paint("▒▒", "33")
                case .dead: line += paint("XX", "31")
                case .unknown: line += paint("··", "90")
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    public static var legend: String {
        [paint("██", "32") + " works",
         paint("▒▒", "33") + " intermittent",
         paint("XX", "31") + " dead",
         paint("··", "90") + " not swept yet",
         paint("@@", "1;36") + " your finger"].joined(separator: "   ")
    }

    public static func bar(_ fraction: Double, width: Int = 30) -> String {
        let filled = Int((fraction * Double(width)).rounded())
        let full = String(repeating: "█", count: max(0, min(width, filled)))
        let rest = String(repeating: "░", count: max(0, width - filled))
        return "\(full)\(rest) \(Int((fraction * 100).rounded()))%"
    }
}
