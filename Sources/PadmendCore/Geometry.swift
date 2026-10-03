import Foundation

/// A point in trackpad-normalized coordinates: x and y both run 0...1, with
/// the origin at the bottom-left corner of the sensor as MultitouchSupport
/// reports it.
public struct Point: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public static func + (a: Point, b: Point) -> Point {
        Point(x: a.x + b.x, y: a.y + b.y)
    }

    public static func - (a: Point, b: Point) -> Point {
        Point(x: a.x - b.x, y: a.y - b.y)
    }

    public static func * (p: Point, s: Double) -> Point {
        Point(x: p.x * s, y: p.y * s)
    }

    public var magnitude: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Point) -> Double { (self - other).magnitude }
}

/// The physical capacitive trace grid of a trackpad.
///
/// Aligning the dead map to the real sensor matters: a damaged trace kills an
/// entire row or column of cells, so a grid that matches the hardware turns
/// "many scattered dead cells" into "trace 11 is gone", which is both a
/// smaller thing to store and a far stronger thing to extrapolate from.
public struct SensorGrid: Equatable, Codable, Sendable {
    public let cols: Int
    public let rows: Int
    /// Physical sensor size in millimetres, used to convert normalized motion
    /// into real distance before applying any pointer gain.
    public let widthMM: Double
    public let heightMM: Double

    public init(cols: Int, rows: Int, widthMM: Double, heightMM: Double) {
        precondition(cols > 0 && rows > 0, "sensor grid must be non-empty")
        self.cols = cols
        self.rows = rows
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    /// The grid reported by a 13-16" Apple Silicon MacBook built-in trackpad.
    /// Used as a fallback when the private API declines to report dimensions.
    public static let appleBuiltInDefault = SensorGrid(
        cols: 26, rows: 18, widthMM: 121.9, heightMM: 74.1)

    public var cellCount: Int { cols * rows }

    /// Index of the cell containing `point`, clamped to the grid.
    public func cell(at point: Point) -> Cell {
        let col = min(cols - 1, max(0, Int((point.x * Double(cols)).rounded(.down))))
        let row = min(rows - 1, max(0, Int((point.y * Double(rows)).rounded(.down))))
        return Cell(col: col, row: row)
    }

    public func index(of cell: Cell) -> Int { cell.row * cols + cell.col }

    public func cell(atIndex index: Int) -> Cell {
        Cell(col: index % cols, row: index / cols)
    }

    public func contains(_ cell: Cell) -> Bool {
        cell.col >= 0 && cell.col < cols && cell.row >= 0 && cell.row < rows
    }

    /// Centre of a cell in normalized coordinates.
    public func center(of cell: Cell) -> Point {
        Point(x: (Double(cell.col) + 0.5) / Double(cols),
              y: (Double(cell.row) + 0.5) / Double(rows))
    }

    /// Converts a normalized displacement into millimetres.
    public func millimetres(_ delta: Point) -> Point {
        Point(x: delta.x * widthMM, y: delta.y * heightMM)
    }

    /// Every cell a straight segment from `from` to `to` passes through,
    /// endpoints included. Supersampled rather than Bresenham because the
    /// grid is tiny and segments are short; correctness beats cleverness here.
    public func cells(along from: Point, to: Point) -> [Cell] {
        let deltaCols = abs(to.x - from.x) * Double(cols)
        let deltaRows = abs(to.y - from.y) * Double(rows)
        let steps = max(1, Int(ceil(max(deltaCols, deltaRows) * 2)))
        var seen: [Cell] = []
        var lastIndex = -1
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let p = Point(x: from.x + (to.x - from.x) * t,
                          y: from.y + (to.y - from.y) * t)
            let c = cell(at: p)
            let i = index(of: c)
            if i != lastIndex {
                seen.append(c)
                lastIndex = i
            }
        }
        return seen
    }
}

public struct Cell: Equatable, Hashable, Codable, Sendable {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}
