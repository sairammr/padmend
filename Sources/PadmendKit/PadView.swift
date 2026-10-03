import AppKit
import PadmendCore

/// Draws the sensor grid as the trackpad itself, bottom row nearest the user.
///
/// The map is shown rather than summarised because a damaged trace is a shape.
/// A user can recognise "the third column from the left is gone" at a glance
/// and cannot do anything useful with a cell count.
public final class PadView: NSView {
    public enum Source {
        case coverage(CoverageMap, fingers: [Point])
        case map(DeadMap)
    }

    public var source: Source? {
        didSet { needsDisplay = true }
    }

    public override var isFlipped: Bool { false }

    private static let worksColor = NSColor.systemGreen
    private static let flakyColor = NSColor.systemYellow
    private static let deadColor = NSColor.systemRed
    private static let unknownColor = NSColor.tertiaryLabelColor
    private static let fingerColor = NSColor.systemTeal

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        guard let source else { return }
        let grid: SensorGrid
        switch source {
        case .coverage(let coverage, _): grid = coverage.grid
        case .map(let map): grid = map.grid
        }

        let inset: CGFloat = 8
        let area = bounds.insetBy(dx: inset, dy: inset)
        let cellWidth = area.width / CGFloat(grid.cols)
        let cellHeight = area.height / CGFloat(grid.rows)

        var fingerCells = Set<Cell>()
        if case .coverage(let coverage, let fingers) = source {
            fingerCells = Set(fingers.map { coverage.grid.cell(at: $0) })
        }

        for row in 0..<grid.rows {
            for col in 0..<grid.cols {
                let cell = Cell(col: col, row: row)
                let rect = NSRect(
                    x: area.minX + CGFloat(col) * cellWidth,
                    y: area.minY + CGFloat(row) * cellHeight,
                    width: cellWidth, height: cellHeight).insetBy(dx: 0.7, dy: 0.7)

                color(for: cell, in: source, isFinger: fingerCells.contains(cell))
                    .setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
    }

    private func color(for cell: Cell, in source: Source, isFinger: Bool) -> NSColor {
        if isFinger { return PadView.fingerColor }

        switch source {
        case .coverage(let coverage, _):
            let hits = coverage.hits(at: cell)
            let transits = coverage.transits(at: cell)
            switch (hits, transits) {
            case (0, 0):
                return PadView.unknownColor.withAlphaComponent(0.25)
            case (0, _):
                return PadView.deadColor
            case (_, 0):
                // Darker where the evidence is thin, so a user can see which
                // parts of the pad still need sweeping.
                let confidence = min(1, Double(hits) / 6)
                return PadView.worksColor
                    .withAlphaComponent(0.35 + 0.65 * confidence)
            default:
                return PadView.flakyColor
            }
        case .map(let map):
            switch map.health(at: cell) {
            case .live: return PadView.worksColor
            case .flaky: return PadView.flakyColor
            case .dead: return PadView.deadColor
            case .unknown: return PadView.unknownColor.withAlphaComponent(0.25)
            }
        }
    }
}

/// The colour key, built from the same colours the view uses.
public final class LegendView: NSStackView {
    public convenience init(includeFinger: Bool) {
        var entries: [(String, NSColor)] = [
            ("works", .systemGreen),
            ("intermittent", .systemYellow),
            ("dead", .systemRed),
            ("not swept", .tertiaryLabelColor),
        ]
        if includeFinger { entries.append(("your finger", .systemTeal)) }

        self.init(views: entries.map { title, color in
            let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 11, height: 11))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 2
            swatch.setContentHuggingPriority(.required, for: .horizontal)

            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor

            let row = NSStackView(views: [swatch, label])
            row.spacing = 4
            return row
        })
        orientation = .horizontal
        spacing = 14
    }
}
