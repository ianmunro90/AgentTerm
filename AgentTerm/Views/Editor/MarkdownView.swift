import Markdown
import SwiftUI
import UIKit
import WebKit

/// Markdown rendered to HTML (GitHub-flavoured: tables, task lists, strikethrough), styled
/// from the terminal theme, with code blocks highlighted like the code view.
struct MarkdownRenderer: MarkupWalker {
    private(set) var html = ""
    private let theme: TerminalTheme
    private var headingIDs: [String: Int] = [:]

    private init(theme: TerminalTheme) {
        self.theme = theme
    }

    /// Stands for the text size in a page; MarkdownView puts the size in.
    static let fontSizeToken = "AGENTTERM-FONT-SIZE"

    /// A complete page for `markdown`. The text size is a CSS variable, `--size`, so it can
    /// change without reloading.
    static func page(for markdown: String, theme: TerminalTheme) -> String {
        var renderer = MarkdownRenderer(theme: theme)
        renderer.visit(Document(parsing: markdown))
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>:root { --size: \(fontSizeToken)px; }
        \(css(theme: theme))</style></head>
        <body>\(renderer.html)</body></html>
        """
    }

    // MARK: Blocks

    mutating func defaultVisit(_ markup: Markup) {
        descendInto(markup)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        wrap("p", paragraph)
    }

    mutating func visitHeading(_ heading: Heading) {
        // GitHub's anchors, so "#section" links work.
        var slug = heading.plainText.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: " ", with: "-")
        if let count = headingIDs[slug] {
            headingIDs[slug] = count + 1
            slug += "-\(count + 1)"
        } else {
            headingIDs[slug] = 0
        }
        html += "<h\(heading.level) id=\"\(Self.escape(slug))\">"
        descendInto(heading)
        html += "</h\(heading.level)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        wrap("blockquote", blockQuote)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
        html += "<pre><code>\(highlighted(code, language: codeBlock.language))</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        html += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ block: HTMLBlock) {
        html += block.rawHTML
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        wrap("ul", list)
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        html += list.startIndex == 1 ? "<ol>" : "<ol start=\"\(list.startIndex)\">"
        descendInto(list)
        html += "</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) {
        if let checkbox = item.checkbox {
            html += "<li class=\"task\"><input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")>"
        } else {
            html += "<li>"
        }
        descendInto(item)
        html += "</li>\n"
    }

    mutating func visitTable(_ table: Markdown.Table) {
        let alignments = table.columnAlignments
        func row(_ cells: some Sequence<Markdown.Table.Cell>, tag: String) {
            html += "<tr>"
            for (index, cell) in cells.enumerated() where cell.colspan > 0 {
                var attributes = ""
                if alignments.indices.contains(index), let alignment = alignments[index] {
                    attributes += " style=\"text-align:\(alignment == .left ? "left" : alignment == .center ? "center" : "right")\""
                }
                if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
                if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }
                html += "<\(tag)\(attributes)>"
                descendInto(cell)
                html += "</\(tag)>"
            }
            html += "</tr>\n"
        }
        html += "<table><thead>"
        row(table.head.cells, tag: "th")
        html += "</thead><tbody>"
        for body in table.body.rows { row(body.cells, tag: "td") }
        html += "</tbody></table>\n"
    }

    // MARK: Inlines

    mutating func visitText(_ text: Markdown.Text) {
        html += Self.escape(text.string)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        html += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        html += "<br>\n"
    }

    mutating func visitInlineCode(_ code: InlineCode) {
        html += "<code>\(Self.escape(code.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        wrap("em", emphasis, newline: false)
    }

    mutating func visitStrong(_ strong: Strong) {
        wrap("strong", strong, newline: false)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        wrap("del", strikethrough, newline: false)
    }

    mutating func visitLink(_ link: Markdown.Link) {
        html += "<a href=\"\(Self.escape(link.destination ?? ""))\""
        if let title = link.title { html += " title=\"\(Self.escape(title))\"" }
        html += ">"
        descendInto(link)
        html += "</a>"
    }

    mutating func visitImage(_ image: Markdown.Image) {
        html += "<img src=\"\(Self.escape(image.source ?? ""))\" alt=\"\(Self.escape(image.plainText))\""
        if let title = image.title { html += " title=\"\(Self.escape(title))\"" }
        html += ">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        html += inlineHTML.rawHTML
    }

    // MARK: Helpers

    private mutating func wrap(_ tag: String, _ markup: Markup, newline: Bool = true) {
        html += "<\(tag)>"
        descendInto(markup)
        html += "</\(tag)>" + (newline ? "\n" : "")
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Fence names that aren't file extensions.
    private static let languageAliases = [
        "python": "py", "javascript": "js", "typescript": "ts", "shell": "sh", "bash": "sh", "zsh": "sh",
        "console": "sh", "shell-session": "sh", "yaml": "yml", "markdown": "md", "ruby": "rb", "rust": "rs",
        "kotlin": "kt", "csharp": "cs", "c#": "cs", "c++": "cpp", "objective-c": "m", "objc": "m", "golang": "go",
        "dockerfile": "dockerfile", "jsonc": "json", "text": "txt", "plaintext": "txt",
    ]

    /// The code view's highlighting, as coloured spans.
    private func highlighted(_ code: String, language: String?) -> String {
        let fence = language?.lowercased().split(separator: " ").first.map(String.init) ?? ""
        let ext = Self.languageAliases[fence] ?? fence
        let text = NSMutableAttributedString(string: code, attributes: [.foregroundColor: theme.editorForeground])
        SyntaxHighlighter.apply(to: text, language: ext.isEmpty ? nil : SyntaxHighlighter.language(forPath: "code." + ext),
                                palette: theme.syntax, boldFont: .monospacedSystemFont(ofSize: 13, weight: .bold))
        var result = ""
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let piece = Self.escape((text.string as NSString).substring(with: range))
            if let color = value as? UIColor, color != theme.editorForeground {
                result += "<span style=\"color:\(color.cssHex)\">\(piece)</span>"
            } else {
                result += piece
            }
        }
        return result
    }

    private static func css(theme: TerminalTheme) -> String {
        let background = theme.editorBackground.cssHex
        let foreground = theme.editorForeground.cssHex
        let muted = theme.editorBackground.blended(with: theme.editorForeground, 0.62).cssHex
        let chrome = theme.editorChrome(0.07).cssHex
        let stripe = theme.editorChrome(0.035).cssHex
        let border = theme.editorChrome(0.2).cssHex
        let link = UIColor(hex: theme.ansi[4]).cssHex
        return """
        :root { color-scheme: \(theme.isLight ? "light" : "dark"); }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; padding: 20px 28px 64px; max-width: 920px; background: \(background); color: \(foreground);
               font: calc(var(--size) + 2px)/1.6 -apple-system, system-ui, sans-serif; word-wrap: break-word; }
        a { color: \(link); text-decoration: none; }
        h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 .6em; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1em; }
        h1, h2 { padding-bottom: .3em; border-bottom: 1px solid \(border); }
        body > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > p { margin: 0; }
        li.task { list-style: none; } li.task > p { display: inline; }
        li.task input { margin: 0 .5em 0 -1.4em; vertical-align: middle; accent-color: \(link); }
        code { font: .88em ui-monospace, Menlo, monospace; background: \(chrome); padding: .15em .4em; border-radius: 5px; }
        pre { background: \(chrome); padding: 12px 16px; border-radius: 8px; overflow-x: auto; line-height: 1.45; }
        pre code { background: none; padding: 0; font-size: var(--size); white-space: pre; }
        blockquote { padding: 0 1em; color: \(muted); border-left: .25em solid \(border); margin-left: 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
        th, td { border: 1px solid \(border); padding: 6px 13px; } th { font-weight: 600; }
        tbody tr:nth-child(2n) { background: \(stripe); }
        img { max-width: 100%; } hr { border: 0; height: 1px; background: \(border); margin: 1.5em 0; }
        """
    }
}

/// Rendered Markdown, read-only. JavaScript is off (a repository's HTML shouldn't run code).
/// Links: same-page anchors scroll, web links open in Safari, links to files call `onOpenFile`.
struct MarkdownView: UIViewRepresentable {
    let html: String
    /// The Markdown file, so relative links resolve against its folder.
    let path: String
    let background: UIColor
    let fontSize: CGFloat
    var findRequest = 0
    var onFontStep: ((Int) -> Void)?
    var onOpenFile: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        if #available(iOS 26.0, *) { view.scrollView.topEdgeEffect.isHidden = true }
        // Pinch sets the text size rather than zooming the page.
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        context.coordinator.pinch.attach(to: view)
        view.isFindInteractionEnabled = true
        context.coordinator.findRequest = findRequest
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.pinch.onStep = onFontStep
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        view.backgroundColor = background
        view.scrollView.backgroundColor = background
        if context.coordinator.loaded != html {
            context.coordinator.loaded = html
            context.coordinator.fontSize = fontSize
            let page = html.replacingOccurrences(of: MarkdownRenderer.fontSizeToken, with: "\(Int(fontSize))")
            view.loadHTMLString(page, baseURL: URL(fileURLWithPath: path))
        } else if context.coordinator.fontSize != fontSize {
            // Our own script (the page's are off), so the reading position stays.
            context.coordinator.fontSize = fontSize
            view.evaluateJavaScript("document.documentElement.style.setProperty('--size', '\(Int(fontSize))px')")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?
        var fontSize: CGFloat = 0
        var findRequest = 0
        let pinch = FontPinch()
        var onOpenFile: ((String) -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                return decisionHandler(.allow)
            }
            if url.isFileURL {
                // Same page: let the anchor scroll. Another file: open it in a tab.
                if url.path == webView.url?.path, url.fragment != nil { return decisionHandler(.allow) }
                onOpenFile?(url.path)
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

extension UIColor {
    var cssHex: String {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return a < 1
            ? String(format: "rgba(%d,%d,%d,%.2f)", byte(r), byte(g), byte(b), a)
            : String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
