import Foundation

/// Turns mosh framebuffers into escape sequences for the local SwiftTerm view, redrawing only
/// rows that changed. Every row is positioned absolutely, so SwiftTerm never scrolls (mosh has
/// no scrollback; tmux provides it).
struct MoshRenderer {
    private var last: MoshFramebuffer?

    mutating func reset() {
        last = nil
    }

    mutating func render(_ frame: MoshFramebuffer) -> String {
        var out = ""
        let previous = last
        let full = previous == nil || previous!.width != frame.width || previous!.height != frame.height

        if full {
            out += "\u{1b}[?25l\u{1b}[0m\u{1b}[r\u{1b}[H\u{1b}[2J"
        } else if previous != frame {
            out += "\u{1b}[?25l"
        }

        for row in 0..<frame.height where full || previous!.rows[row] != frame.rows[row] {
            out += draw(row: frame.rows[row], index: row, width: frame.width)
        }

        if full || previous!.windowTitle != frame.windowTitle {
            out += "\u{1b}]0;\(frame.windowTitle)\u{07}"
        }
        if !full, frame.bellCount != previous!.bellCount {
            out += "\u{07}"
        }
        if full || previous!.clipboard != frame.clipboard, !frame.clipboard.isEmpty {
            out += "\u{1b}]52;c;\(frame.clipboard)\u{07}"
        }
        if full || previous!.reverseVideo != frame.reverseVideo {
            out += frame.reverseVideo ? "\u{1b}[?5h" : "\u{1b}[?5l"
        }
        if full || previous!.bracketedPaste != frame.bracketedPaste {
            out += frame.bracketedPaste ? "\u{1b}[?2004h" : "\u{1b}[?2004l"
        }
        if full || previous!.mouseReportingMode != frame.mouseReportingMode {
            out += "\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1001l\u{1b}[?1000l"
            if frame.mouseReportingMode != 0 { out += "\u{1b}[?\(frame.mouseReportingMode)h" }
        }
        if full || previous!.mouseFocusEvent != frame.mouseFocusEvent {
            out += frame.mouseFocusEvent ? "\u{1b}[?1004h" : "\u{1b}[?1004l"
        }
        if full || previous!.mouseEncodingMode != frame.mouseEncodingMode {
            out += "\u{1b}[?1015l\u{1b}[?1006l\u{1b}[?1005l"
            if frame.mouseEncodingMode != 0 { out += "\u{1b}[?\(frame.mouseEncodingMode)h" }
        }

        if !out.isEmpty || previous?.cursorRow != frame.cursorRow || previous?.cursorCol != frame.cursorCol
            || previous?.cursorVisible != frame.cursorVisible {
            out += "\u{1b}[0m\u{1b}[\(frame.cursorRow + 1);\(frame.cursorCol + 1)H"
            out += frame.cursorVisible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        }

        last = frame
        return out
    }

    private func draw(row: MoshRow, index: Int, width: Int) -> String {
        var out = "\u{1b}[\(index + 1);1H"
        var current: MoshRenditions?
        var col = 0
        var resync = false
        while col < width {
            let cell = row.cells[col]
            if resync {
                // SwiftTerm's idea of a character's width may differ from glibc's; re-anchor.
                out += "\u{1b}[\(index + 1);\(col + 1)H"
                resync = false
            }
            if current != cell.renditions {
                out += cell.renditions.sgr
                current = cell.renditions
            }
            if cell.isEmpty {
                out += " "
            } else {
                if cell.fallback { out += "\u{00A0}" }
                out += cell.contents
                resync = cell.wide || cell.contents.unicodeScalars.contains { $0.value >= 0x300 }
            }
            col += cell.width
        }
        return out
    }
}
