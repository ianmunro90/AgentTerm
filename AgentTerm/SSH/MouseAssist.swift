import Foundation

/// Fat-finger help for dragging tmux pane borders on a touch screen.
///
/// A border is one cell wide (about 7 pt at small font sizes) and iOS only recognises a drag
/// after ~10 pt of movement, so the press SwiftTerm reports usually lands a few cells off the
/// border and tmux starts a text selection instead of a resize. When a press turns out to start
/// a drag, it is moved onto a border line drawn within a few cells. Taps are never moved, so
/// tapping near a border still selects that pane.
enum MouseAssist {
    /// An SGR (mode 1006) mouse report: ESC [ < button ; x ; y M|m, with 1-based x/y.
    struct Report: Equatable {
        var button: Int
        var x: Int
        var y: Int
        var isRelease: Bool

        var isMotion: Bool { button & 32 != 0 }
        var isWheel: Bool { button & 64 != 0 }
        /// A button going down (not motion, wheel or release).
        var isPress: Bool { !isRelease && !isMotion && !isWheel && button & 3 != 3 }

        init?(_ bytes: [UInt8]) {
            guard bytes.count >= 9, bytes.starts(with: [0x1B, 0x5B, 0x3C]),
                  let last = bytes.last, last == UInt8(ascii: "M") || last == UInt8(ascii: "m")
            else { return nil }
            let fields = String(decoding: bytes[3..<(bytes.count - 1)], as: UTF8.self).split(separator: ";")
            guard fields.count == 3, let b = Int(fields[0]), let x = Int(fields[1]), let y = Int(fields[2]) else { return nil }
            button = b
            self.x = x
            self.y = y
            isRelease = last == UInt8(ascii: "m")
        }

        var bytes: [UInt8] {
            Array("\u{1b}[<\(button);\(x);\(y)\(isRelease ? "m" : "M")".utf8)
        }
    }

    /// Box-drawing characters tmux uses for pane borders (single, heavy, double, dashed).
    private static let vertical: Set<Character> = ["│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋"]
    private static let horizontal: Set<Character> = ["─", "━", "═", "╌", "╍", "┄", "┅", "┈", "┉"]
    private static let junctions: Set<Character> = [
        "├", "┤", "┬", "┴", "┼", "┣", "┫", "┳", "┻", "╋", "╠", "╣", "╦", "╩", "╬",
        "┌", "┐", "└", "┘", "┏", "┓", "┗", "┛", "╔", "╗", "╚", "╝",
    ]

    static func isBorder(_ c: Character?) -> Bool {
        guard let c else { return false }
        return vertical.contains(c) || horizontal.contains(c) || junctions.contains(c)
    }

    /// Moves a drag's press onto the nearest pane border within reach, or returns it unchanged.
    /// `character(col, row)` reads the screen (0-based). Rows are taller than columns, so a row
    /// counts as `rowWeight` columns when comparing distances.
    static func snap(_ press: Report, columnReach: Int = 3, rowReach: Int = 2, rowWeight: Double = 1.6,
                     character: (Int, Int) -> Character?) -> Report {
        let col = press.x - 1
        let row = press.y - 1
        if isBorder(character(col, row)) { return press }

        var best: (distance: Double, col: Int, row: Int)?
        func consider(_ c: Int, _ r: Int, _ distance: Double, _ accepts: Set<Character>) {
            guard let ch = character(c, r), accepts.contains(ch) || junctions.contains(ch) else { return }
            if best == nil || distance < best!.distance { best = (distance, c, r) }
        }
        for d in 1...max(1, columnReach) {
            consider(col - d, row, Double(d), vertical)
            consider(col + d, row, Double(d), vertical)
        }
        for d in 1...max(1, rowReach) {
            consider(col, row - d, Double(d) * rowWeight, horizontal)
            consider(col, row + d, Double(d) * rowWeight, horizontal)
        }
        guard let best else { return press }
        var snapped = press
        snapped.x = best.col + 1
        snapped.y = best.row + 1
        return snapped
    }
}
