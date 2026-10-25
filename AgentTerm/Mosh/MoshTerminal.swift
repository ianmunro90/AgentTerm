import Foundation

// A value-type model of mosh's Terminal::Framebuffer plus an interpreter for the escape
// sequences mosh-server's Display::new_frame emits. States must be cheap to copy: the server
// sends each screen update as a diff against a specific earlier state, which is often not the
// newest one, so the client keeps several and applies each diff to the right base.
// Semantics follow mosh/src/terminal (terminalframebuffer.cc, terminalfunctions.cc, terminal.cc).

enum MoshColor: Equatable {
    case none
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

struct MoshRenditions: Equatable {
    static let bold: UInt8 = 1, italic: UInt8 = 2, underlined: UInt8 = 4
    static let blink: UInt8 = 8, inverse: UInt8 = 16, invisible: UInt8 = 32

    var attributes: UInt8 = 0
    var foreground: MoshColor = .none
    var background: MoshColor = .none

    /// Renditions for an erased cell: only the background colour survives (BCE).
    var backgroundOnly: MoshRenditions { MoshRenditions(background: background) }

    /// Applies one SGR parameter list, like Renditions::set_rendition.
    mutating func apply(sgr params: [Int]) {
        var i = 0
        let params = params.isEmpty ? [0] : params
        while i < params.count {
            let p = params[i]
            switch p {
            case 0: self = MoshRenditions()
            case 1: attributes |= Self.bold
            case 3: attributes |= Self.italic
            case 4: attributes |= Self.underlined
            case 5: attributes |= Self.blink
            case 7: attributes |= Self.inverse
            case 8: attributes |= Self.invisible
            case 22: attributes &= ~Self.bold
            case 23: attributes &= ~Self.italic
            case 24: attributes &= ~Self.underlined
            case 25: attributes &= ~Self.blink
            case 27: attributes &= ~Self.inverse
            case 28: attributes &= ~Self.invisible
            case 30...37: foreground = .indexed(UInt8(p - 30))
            case 39: foreground = .none
            case 40...47: background = .indexed(UInt8(p - 40))
            case 49: background = .none
            case 90...97: foreground = .indexed(UInt8(p - 90 + 8))
            case 100...107: background = .indexed(UInt8(p - 100 + 8))
            case 38, 48:
                var color: MoshColor?
                if i + 2 < params.count, params[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: params[i + 2]))
                    i += 2
                } else if i + 4 < params.count, params[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: params[i + 2]), UInt8(clamping: params[i + 3]), UInt8(clamping: params[i + 4]))
                    i += 4
                }
                if let color {
                    if p == 38 { foreground = color } else { background = color }
                }
            default: break
            }
            i += 1
        }
    }

    /// SGR string that recreates these renditions from scratch.
    var sgr: String {
        var s = "\u{1b}[0"
        if attributes & Self.bold != 0 { s += ";1" }
        if attributes & Self.italic != 0 { s += ";3" }
        if attributes & Self.underlined != 0 { s += ";4" }
        if attributes & Self.blink != 0 { s += ";5" }
        if attributes & Self.inverse != 0 { s += ";7" }
        if attributes & Self.invisible != 0 { s += ";8" }
        s += Self.code(foreground, base: 30, extended: 38)
        s += Self.code(background, base: 40, extended: 48)
        return s + "m"
    }

    private static func code(_ color: MoshColor, base: Int, extended: Int) -> String {
        switch color {
        case .none: return ""
        case .indexed(let n) where n < 8: return ";\(base + Int(n))"
        case .indexed(let n): return ";\(extended);5;\(n)"
        case .rgb(let r, let g, let b): return ";\(extended);2;\(r);\(g);\(b)"
        }
    }
}

struct MoshCell: Equatable {
    var contents = ""
    var renditions = MoshRenditions()
    var wide = false
    var fallback = false

    var isEmpty: Bool { contents.isEmpty }
    var width: Int { wide ? 2 : 1 }

    init(renditions: MoshRenditions = MoshRenditions()) {
        self.renditions = renditions
    }
}

struct MoshRow: Equatable {
    var cells: [MoshCell]
    var wrap = false

    init(width: Int, renditions: MoshRenditions) {
        cells = Array(repeating: MoshCell(renditions: renditions), count: width)
    }
}

struct MoshFramebuffer: Equatable {
    private(set) var width: Int
    private(set) var height: Int
    var rows: [MoshRow]

    var cursorRow = 0
    var cursorCol = 0
    private var combiningRow = -1
    private var combiningCol = -1
    private var nextPrintWillWrap = false
    private var scrollTop = 0
    private var scrollBottom: Int
    private var renditions = MoshRenditions()

    var cursorVisible = true
    var reverseVideo = false
    var bracketedPaste = false
    var mouseReportingMode = 0
    var mouseFocusEvent = false
    var mouseEncodingMode = 0
    var windowTitle = ""
    var bellCount = 0
    var clipboard = ""

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        scrollBottom = height - 1
        rows = Array(repeating: MoshRow(width: width, renditions: MoshRenditions()), count: height)
    }

    // MARK: Instructions

    mutating func resize(width newWidth: Int, height newHeight: Int) {
        guard newWidth > 0, newHeight > 0 else { return }
        if newWidth != width || newHeight != height {
            scrollTop = 0
            scrollBottom = newHeight - 1
        }
        let blank = MoshRow(width: newWidth, renditions: renditions.backgroundOnly)
        if newHeight < rows.count {
            rows.removeLast(rows.count - newHeight)
        }
        if newWidth != width {
            for index in rows.indices {
                rows[index].wrap = false
                if newWidth < width {
                    rows[index].cells.removeLast(width - newWidth)
                } else {
                    rows[index].cells += Array(repeating: MoshCell(renditions: renditions.backgroundOnly), count: newWidth - width)
                }
            }
        }
        if newHeight > rows.count {
            rows += Array(repeating: blank, count: newHeight - rows.count)
        }
        width = newWidth
        height = newHeight
        snapCursor()
        if combiningCol >= width || combiningRow >= height {
            combiningCol = -1
            combiningRow = -1
        }
    }

    /// Interprets one `hoststring` from the server.
    mutating func apply(_ bytes: [UInt8]) {
        let scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            switch scalar.value {
            case 0x07: bellCount += 1
            case 0x08: moveCol(-1, relative: true)
            case 0x0A, 0x0B, 0x0C: moveRowsAutoscroll(1)
            case 0x0D: moveCol(0)
            case 0x1B:
                i = escape(scalars, from: i + 1)
                continue
            case 0x00..<0x20, 0x7F..<0xA0: break
            default: print(scalar)
            }
            i += 1
        }
    }

    // MARK: Parsing

    /// Handles the sequence after ESC; returns the index after it.
    private mutating func escape(_ s: [Unicode.Scalar], from start: Int) -> Int {
        guard start < s.count else { return start }
        switch s[start] {
        case "[":
            var i = start + 1
            var privateMarker = false
            var paramText = ""
            if i < s.count, s[i] == "?" {
                privateMarker = true
                i += 1
            }
            while i < s.count, (0x20...0x3F).contains(s[i].value) {
                paramText.unicodeScalars.append(s[i])
                i += 1
            }
            guard i < s.count else { return i }
            let final = s[i]
            let params = paramText.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
            csi(final: final, params: paramText.isEmpty ? [] : params, private: privateMarker)
            return i + 1
        case "]":
            var i = start + 1
            var text = ""
            while i < s.count {
                if s[i].value == 0x07 { i += 1; break }
                if s[i].value == 0x1B, i + 1 < s.count, s[i + 1] == "\\" { i += 2; break }
                text.unicodeScalars.append(s[i])
                i += 1
            }
            osc(text)
            return i
        default:
            return start + 1
        }
    }

    private mutating func csi(final: Unicode.Scalar, params: [Int], private isPrivate: Bool) {
        func param(_ n: Int, _ defaultValue: Int) -> Int {
            let value = n < params.count ? params[n] : 0
            return value < 1 ? defaultValue : value
        }
        if isPrivate {
            guard final == "h" || final == "l" else { return }
            let on = final == "h"
            for mode in params {
                switch mode {
                case 5: reverseVideo = on
                case 25: cursorVisible = on
                case 2004: bracketedPaste = on
                case 1000...1003: mouseReportingMode = on ? mode : 0
                case 1004: mouseFocusEvent = on
                case 1005, 1006, 1015: mouseEncodingMode = on ? mode : 0
                default: break
                }
            }
            return
        }
        switch final {
        case "H", "f":
            moveRow(param(0, 1) - 1)
            moveCol(param(1, 1) - 1)
        case "A": moveRow(-param(0, 1), relative: true)
        case "B": moveRow(param(0, 1), relative: true)
        case "C": moveCol(param(0, 1), relative: true)
        case "D": moveCol(-param(0, 1), relative: true)
        case "J":
            switch param(0, 0) {
            case 0:
                clearLine(cursorRow, from: cursorCol, to: width - 1)
                for row in (cursorRow + 1)..<max(cursorRow + 1, height) { resetRow(row) }
            case 1:
                for row in 0..<cursorRow { resetRow(row) }
                clearLine(cursorRow, from: 0, to: cursorCol)
            case 2:
                for row in 0..<height { resetRow(row) }
            default: break
            }
        case "K":
            switch param(0, 0) {
            case 0: clearLine(cursorRow, from: cursorCol, to: width - 1)
            case 1: clearLine(cursorRow, from: 0, to: cursorCol)
            case 2: resetRow(cursorRow)
            default: break
            }
        case "X":
            clearLine(cursorRow, from: cursorCol, to: min(width - 1, cursorCol + param(0, 1) - 1))
        case "r":
            let top = param(0, 1)
            let bottom = param(1, height)
            guard bottom > top, top <= height, !(top == 0 && bottom == 1) else { return }
            scrollTop = max(0, top - 1)
            scrollBottom = max(scrollTop, min(height - 1, bottom - 1))
            moveRow(0)
            moveCol(0)
        case "m":
            renditions.apply(sgr: params)
        default:
            break
        }
    }

    private mutating func osc(_ text: String) {
        guard let separator = text.firstIndex(of: ";") else { return }
        let command = text[..<separator]
        let argument = String(text[text.index(after: separator)...])
        switch command {
        case "0", "2": windowTitle = argument
        case "52":
            if let dataStart = argument.firstIndex(of: ";") {
                clipboard = String(argument[argument.index(after: dataStart)...])
            }
        default: break // icon name (1) and hyperlinks (8) aren't shown
        }
    }

    // MARK: Emulator::print

    private mutating func print(_ scalar: Unicode.Scalar) {
        let chwidth = MoshCharWidth.width(scalar)
        switch chwidth {
        case 1, 2:
            if nextPrintWillWrap {
                rows[cursorRow].wrap = true
                moveCol(0)
                moveRowsAutoscroll(1)
            } else if chwidth == 2, cursorCol == width - 1 {
                resetCell(cursorRow, cursorCol)
                rows[cursorRow].wrap = false
                moveCol(0)
                moveRowsAutoscroll(1)
            }
            resetCell(cursorRow, cursorCol)
            rows[cursorRow].cells[cursorCol].contents.unicodeScalars.append(scalar)
            rows[cursorRow].cells[cursorCol].wide = chwidth == 2
            rows[cursorRow].cells[cursorCol].renditions = renditions
            if chwidth == 2, cursorCol + 1 < width {
                resetCell(cursorRow, cursorCol + 1)
            }
            moveCol(chwidth, relative: true, implicit: true)
        default:
            guard combiningCol >= 0, combiningRow >= 0, combiningCol < width, combiningRow < height else { return }
            if rows[combiningRow].cells[combiningCol].isEmpty {
                rows[combiningRow].cells[combiningCol].fallback = true
                moveCol(1, relative: true, implicit: true)
            }
            if rows[combiningRow].cells[combiningCol].contents.utf8.count < 32 {
                rows[combiningRow].cells[combiningCol].contents.unicodeScalars.append(scalar)
            }
        }
    }

    // MARK: Cursor (DrawState)

    private mutating func snapCursor() {
        cursorRow = min(max(cursorRow, 0), height - 1)
        cursorCol = min(max(cursorCol, 0), width - 1)
    }

    private mutating func newGrapheme() {
        combiningCol = cursorCol
        combiningRow = cursorRow
    }

    private mutating func moveRow(_ n: Int, relative: Bool = false) {
        cursorRow = relative ? cursorRow + n : n
        snapCursor()
        newGrapheme()
        nextPrintWillWrap = false
    }

    private mutating func moveCol(_ n: Int, relative: Bool = false, implicit: Bool = false) {
        if implicit { newGrapheme() }
        cursorCol = relative ? cursorCol + n : n
        if implicit { nextPrintWillWrap = cursorCol >= width }
        snapCursor()
        if !implicit {
            newGrapheme()
            nextPrintWillWrap = false
        }
    }

    private mutating func moveRowsAutoscroll(_ n: Int) {
        if cursorRow < scrollTop || cursorRow > scrollBottom {
            moveRow(n, relative: true)
            return
        }
        if cursorRow + n > scrollBottom {
            let count = cursorRow + n - scrollBottom
            scroll(count)
            moveRow(-count, relative: true)
        } else if cursorRow + n < scrollTop {
            let count = cursorRow + n - scrollTop
            scroll(count)
            moveRow(-count, relative: true)
        }
        moveRow(n, relative: true)
    }

    // MARK: Framebuffer editing

    private var blankRow: MoshRow { MoshRow(width: width, renditions: renditions.backgroundOnly) }

    private mutating func scroll(_ n: Int) {
        if n >= 0 {
            let count = min(n, scrollBottom + 1 - scrollTop)
            guard count > 0 else { return }
            rows.removeSubrange(scrollTop..<(scrollTop + count))
            rows.insert(contentsOf: Array(repeating: blankRow, count: count), at: scrollBottom + 1 - count)
        } else {
            let count = min(-n, scrollBottom + 1 - scrollTop)
            guard count > 0 else { return }
            rows.removeSubrange((scrollBottom + 1 - count)...scrollBottom)
            rows.insert(contentsOf: Array(repeating: blankRow, count: count), at: scrollTop)
        }
    }

    private mutating func resetCell(_ row: Int, _ col: Int) {
        rows[row].cells[col] = MoshCell(renditions: renditions.backgroundOnly)
    }

    private mutating func resetRow(_ row: Int) {
        rows[row] = blankRow
    }

    private mutating func clearLine(_ row: Int, from start: Int, to end: Int) {
        guard start <= end else { return }
        for col in start...end { resetCell(row, col) }
    }
}
