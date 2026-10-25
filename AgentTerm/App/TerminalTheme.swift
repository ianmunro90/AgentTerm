import SwiftTerm
import SwiftUI
import UIKit

/// A terminal colour scheme: background/foreground/cursor plus the 16 ANSI colours.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isLight: Bool
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    /// black, red, green, yellow, blue, magenta, cyan, white, then the bright variants.
    let ansi: [String]

    static let defaultID = "agentterm-dark"

    /// The editor's syntax colours for this theme, from its well-known editor counterpart
    /// (deriving them from the 16 ANSI colours reads badly: Solarized's "bright black" is its
    /// background).
    var syntax: SyntaxPalette { SyntaxPalette.forTheme(id) }

    /// Editor chrome derived from the terminal colours.
    var editorBackground: UIColor { UIColor(hex: background) }
    var editorForeground: UIColor { UIColor(hex: foreground) }
    var editorGutter: UIColor { UIColor(hex: foreground).withAlphaComponent(0.38) }
    var diffAdded: UIColor { UIColor(hex: ansi[2]).withAlphaComponent(isLight ? 0.16 : 0.22) }
    var diffRemoved: UIColor { UIColor(hex: ansi[1]).withAlphaComponent(isLight ? 0.14 : 0.22) }
    var diffHunk: UIColor { UIColor(hex: ansi[6]) }
    /// Behind search matches (and a revealed match's flash). Light themes' "yellow" is often
    /// dark (GitHub Light's is brown), so they get amber.
    var matchHighlight: UIColor {
        isLight ? UIColor(red: 1, green: 0.78, blue: 0.2, alpha: 0.5) : UIColor(hex: ansi[3]).withAlphaComponent(0.4)
    }
    /// Opposite added or removed lines in a side-by-side diff.
    var diffFiller: UIColor { UIColor(hex: foreground).withAlphaComponent(isLight ? 0.05 : 0.04) }
    /// Gutter change marks: added, modified, deleted.
    var markAdded: UIColor { UIColor(hex: ansi[2]) }
    var markModified: UIColor { UIColor(hex: ansi[4]) }
    var markDeleted: UIColor { UIColor(hex: ansi[1]) }
    /// Problems (squiggles, ruler ticks, the Problems list): red errors, yellow warnings (a
    /// light theme's dark yellow reads well on white), blue information, faint hints.
    func problemColor(_ severity: LanguageServer.Diagnostic.Severity) -> UIColor {
        switch severity {
        case .error: UIColor(hex: ansi[1])
        case .warning: UIColor(hex: ansi[3])
        case .information: UIColor(hex: ansi[4])
        case .hint: UIColor(hex: foreground).withAlphaComponent(0.5)
        }
    }
    /// Tab strip and inactive tabs: the background nudged towards the foreground.
    func editorChrome(_ amount: CGFloat) -> UIColor { UIColor(hex: background).blended(with: UIColor(hex: foreground), amount) }

    static func named(_ id: String?) -> TerminalTheme {
        all.first { $0.id == id } ?? all[0]
    }

    func apply(to view: TerminalView) {
        view.installColors(ansi.map { Self.terminalColor($0) })
        view.nativeBackgroundColor = UIColor(hex: background)
        view.nativeForegroundColor = UIColor(hex: foreground)
        view.caretColor = UIColor(hex: cursor)
        view.selectedTextBackgroundColor = UIColor(hex: selection)
        view.keyboardAppearance = isLight ? .light : .dark
    }

    var backgroundColor: SwiftUI.Color { SwiftUI.Color(uiColor: UIColor(hex: background)) }
    var swatch: [SwiftUI.Color] { [1, 2, 3, 4, 5, 6].map { SwiftUI.Color(uiColor: UIColor(hex: ansi[$0])) } }

    private static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> UInt16 { UInt16((value >> shift) & 0xFF) * 257 }
        return SwiftTerm.Color(red: channel(16), green: channel(8), blue: channel(0))
    }

    static let all: [TerminalTheme] = [
        TerminalTheme(
            id: defaultID, name: "AgentTerm Dark", isLight: false,
            background: "#0F1217", foreground: "#E6E6E6", cursor: "#6CB6FF", selection: "#2D3B4F",
            ansi: ["#1D2129", "#E5534B", "#57AB5A", "#C69026", "#539BF5", "#B083F0", "#39C5CF", "#ADBAC7",
                   "#636E7B", "#FF938A", "#6BC46D", "#DAAA3F", "#6CB6FF", "#DCBDFB", "#56D4DD", "#CDD9E5"]
        ),
        TerminalTheme(
            id: "dracula", name: "Dracula", isLight: false,
            background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
            ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                   "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
        ),
        TerminalTheme(
            id: "nord", name: "Nord", isLight: false,
            background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
            ansi: ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                   "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]
        ),
        TerminalTheme(
            id: "gruvbox-dark", name: "Gruvbox Dark", isLight: false,
            background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
            ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                   "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]
        ),
        TerminalTheme(
            id: "tokyo-night", name: "Tokyo Night", isLight: false,
            background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selection: "#33467C",
            ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                   "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]
        ),
        TerminalTheme(
            id: "catppuccin-mocha", name: "Catppuccin Mocha", isLight: false,
            background: "#1E1E2E", foreground: "#CDD6F4", cursor: "#F5E0DC", selection: "#45475A",
            ansi: ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                   "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]
        ),
        TerminalTheme(
            id: "solarized-dark", name: "Solarized Dark", isLight: false,
            background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                   "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
        ),
        TerminalTheme(
            id: "solarized-light", name: "Solarized Light", isLight: true,
            background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
            ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                   "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
        ),
        TerminalTheme(
            id: "github-light", name: "GitHub Light", isLight: true,
            background: "#FFFFFF", foreground: "#24292F", cursor: "#0969DA", selection: "#DDF4FF",
            ansi: ["#24292F", "#CF222E", "#116329", "#4D2D00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
                   "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8C959F"]
        ),
    ]
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// App-wide preferences shared by every window.
@MainActor
final class AppSettings: ObservableObject {
    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    @Published var defaultThemeID: String {
        didSet { UserDefaults.standard.set(defaultThemeID, forKey: "defaultThemeID") }
    }

    @Published var autoHideSidebar: Bool {
        didSet { UserDefaults.standard.set(autoHideSidebar, forKey: "autoHideSidebar") }
    }

    init() {
        // iPhone: smaller, for more columns (13 pt gives about 45 in portrait).
        fontSize = UserDefaults.standard.object(forKey: "fontSize") as? CGFloat ?? (Device.isPhone ? 11 : 14)
        defaultThemeID = UserDefaults.standard.string(forKey: "defaultThemeID") ?? TerminalTheme.defaultID
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-theme"), CommandLine.arguments.indices.contains(index + 1) {
            defaultThemeID = CommandLine.arguments[index + 1]
        }
        #endif
        autoHideSidebar = UserDefaults.standard.object(forKey: "autoHideSidebar") as? Bool ?? true
    }

    func theme(for host: HostProfile) -> TerminalTheme {
        TerminalTheme.named(host.themeID ?? defaultThemeID)
    }
}

/// Syntax colours for the editor, one per token kind.
struct SyntaxPalette {
    let comment, string, number, keyword, control, type, function, property, tag, heading, emphasis: UIColor

    init(comment: String, string: String, number: String, keyword: String, control: String, type: String,
         function: String, property: String, tag: String, heading: String, emphasis: String) {
        self.comment = UIColor(hex: comment)
        self.string = UIColor(hex: string)
        self.number = UIColor(hex: number)
        self.keyword = UIColor(hex: keyword)
        self.control = UIColor(hex: control)
        self.type = UIColor(hex: type)
        self.function = UIColor(hex: function)
        self.property = UIColor(hex: property)
        self.tag = UIColor(hex: tag)
        self.heading = UIColor(hex: heading)
        self.emphasis = UIColor(hex: emphasis)
    }

    static func forTheme(_ id: String) -> SyntaxPalette {
        switch id {
        case "dracula":
            SyntaxPalette(comment: "#6272A4", string: "#F1FA8C", number: "#BD93F9", keyword: "#FF79C6", control: "#FF79C6",
                          type: "#8BE9FD", function: "#50FA7B", property: "#8BE9FD", tag: "#FF79C6", heading: "#BD93F9", emphasis: "#FFB86C")
        case "nord":
            SyntaxPalette(comment: "#616E88", string: "#A3BE8C", number: "#B48EAD", keyword: "#81A1C1", control: "#81A1C1",
                          type: "#8FBCBB", function: "#88C0D0", property: "#D8DEE9", tag: "#81A1C1", heading: "#88C0D0", emphasis: "#EBCB8B")
        case "gruvbox-dark":
            SyntaxPalette(comment: "#928374", string: "#B8BB26", number: "#D3869B", keyword: "#FB4934", control: "#FB4934",
                          type: "#FABD2F", function: "#8EC07C", property: "#83A598", tag: "#FE8019", heading: "#FABD2F", emphasis: "#FE8019")
        case "tokyo-night":
            SyntaxPalette(comment: "#565F89", string: "#9ECE6A", number: "#FF9E64", keyword: "#BB9AF7", control: "#BB9AF7",
                          type: "#2AC3DE", function: "#7AA2F7", property: "#73DACA", tag: "#F7768E", heading: "#7AA2F7", emphasis: "#E0AF68")
        case "catppuccin-mocha":
            SyntaxPalette(comment: "#6C7086", string: "#A6E3A1", number: "#FAB387", keyword: "#CBA6F7", control: "#CBA6F7",
                          type: "#F9E2AF", function: "#89B4FA", property: "#B4BEFE", tag: "#CBA6F7", heading: "#F38BA8", emphasis: "#F9E2AF")
        case "solarized-dark":
            SyntaxPalette(comment: "#586E75", string: "#2AA198", number: "#D33682", keyword: "#859900", control: "#859900",
                          type: "#B58900", function: "#268BD2", property: "#268BD2", tag: "#268BD2", heading: "#CB4B16", emphasis: "#B58900")
        case "solarized-light":
            SyntaxPalette(comment: "#93A1A1", string: "#2AA198", number: "#D33682", keyword: "#859900", control: "#859900",
                          type: "#B58900", function: "#268BD2", property: "#268BD2", tag: "#268BD2", heading: "#CB4B16", emphasis: "#B58900")
        case "github-light":
            SyntaxPalette(comment: "#6E7781", string: "#0A3069", number: "#0550AE", keyword: "#CF222E", control: "#CF222E",
                          type: "#953800", function: "#8250DF", property: "#0550AE", tag: "#116329", heading: "#0550AE", emphasis: "#953800")
        default: // AgentTerm Dark: VS Code Dark+
            SyntaxPalette(comment: "#6A9955", string: "#CE9178", number: "#B5CEA8", keyword: "#569CD6", control: "#C586C0",
                          type: "#4EC9B0", function: "#DCDCAA", property: "#9CDCFE", tag: "#569CD6", heading: "#569CD6", emphasis: "#D7BA7D")
        }
    }
}

extension UIColor {
    /// Mixes `amount` (0…1) of `other` into this colour.
    func blended(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * amount, green: g1 + (g2 - g1) * amount, blue: b1 + (b2 - b1) * amount, alpha: 1)
    }
}
