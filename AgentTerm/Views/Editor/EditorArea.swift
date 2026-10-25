import SwiftUI
import UIKit

/// The editor's main area: a strip of open tabs over the selected tab, read-only.
struct EditorArea: View {
    @ObservedObject var workspace: EditorWorkspace
    /// Observed for `revision`: open tabs reload after a refresh or git operation.
    @ObservedObject private var explorer: ExplorerModel
    let onTerminal: () -> Void
    @EnvironmentObject private var settings: AppSettings
    /// Too narrow for two sides of a diff (iPad mini in portrait beside the side bar, Split
    /// View, iPhone in portrait): comparisons show inline, with no side-by-side option.
    @State private var isNarrow = false

    init(workspace: EditorWorkspace, onTerminal: @escaping () -> Void) {
        self.workspace = workspace
        explorer = workspace.explorer
        self.onTerminal = onTerminal
    }

    /// The host's terminal theme (its override, or the app default).
    private var theme: TerminalTheme { settings.theme(for: workspace.session.host) }

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty {
                TabStrip(workspace: workspace, theme: theme)
                Divider()
            }
            if let tab = workspace.selectedTab {
                // `inline` is passed in (not read off the workspace) so a toggle re-renders the tab.
                EditorTabView(tab: tab, workspace: workspace, theme: theme, inline: workspace.inlineDiffs || isNarrow,
                              markdownSource: workspace.markdownSource, fontSize: settings.fontSize,
                              revision: explorer.revision,
                              reveal: workspace.reveal?.path == tab.path ? workspace.reveal : nil,
                              findRequest: workspace.findRequest,
                              problems: tab.kind == .file ? workspace.diagnostics[tab.path] ?? [] : []).id(tab.id)
            } else {
                ContentUnavailableView(
                    "No File Open", systemImage: "doc.text",
                    description: Text("Open a file from the Explorer, or a change or commit from Source Control.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: theme.editorBackground))
            }
        }
        // The tab-strip colour runs up under the navigation bar, so title and tabs read as one
        // band (the area above the tabs showed the window colour before).
        .background(Color(uiColor: theme.editorChrome(0.09)).ignoresSafeArea())
        .onGeometryChange(for: Bool.self) { $0.size.width < 480 } action: { isNarrow = $0 }
        // Light themes get light controls (menus, the empty-tab message) in the editor.
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        .environment(\.editorTheme, theme)
        .toolbarColorScheme(theme.isLight ? .light : .dark, for: .navigationBar)
        // No bar material: it tinted the area above the tabs differently from the tab strip.
        .toolbarBackground(.hidden, for: .navigationBar)
        // iPadOS 26+ fades content under the bar (the scroll edge effect); with the bar
        // transparent that showed as a band of its own above the tabs.
        .hidesTopScrollEdgeEffect()
        .sheet(isPresented: $workspace.showingQuickOpen) {
            QuickOpenView(workspace: workspace)
                .environment(\.editorTheme, theme)
        }
        .navigationTitle(workspace.selectedTab?.title ?? "Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if Device.isPhone {
                    phoneToolbar
                } else {
                    wideToolbar
                }
            }
        }
    }

    /// iPhone: problems, Claude and the terminal, the rest in a menu (the bar fits five).
    @ViewBuilder
    private var phoneToolbar: some View {
        if let tab = workspace.selectedTab {
            if tab.kind == .file, let problems = workspace.diagnostics[tab.path], problems.contains(where: { $0.severity != .hint }) {
                ProblemsButton(workspace: workspace, path: tab.path, problems: problems, theme: theme, fontSize: settings.fontSize)
            }
            claudeMenu(for: tab)
        }
        Menu("More", systemImage: "ellipsis.circle") {
            if let tab = workspace.selectedTab {
                if tab.isMarkdown {
                    Button(workspace.markdownSource ? "Show Preview" : "Show Source",
                           systemImage: workspace.markdownSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") {
                        workspace.markdownSource.toggle()
                    }
                }
                if tab.isComparison, !isNarrow {
                    Button(workspace.inlineDiffs ? "Side by Side" : "Inline",
                           systemImage: workspace.inlineDiffs ? "rectangle.split.2x1" : "rectangle.stack") {
                        workspace.inlineDiffs.toggle()
                    }
                }
                Button("Find in File", systemImage: "text.magnifyingglass", action: workspace.findInFile)
                    .keyboardShortcut("f", modifiers: .command)
            }
            Button("Go to File", systemImage: "doc.text.magnifyingglass") { workspace.showingQuickOpen = true }
                .keyboardShortcut("p", modifiers: .command)
        }
        Button("Terminal", systemImage: "terminal", action: onTerminal)
            .keyboardShortcut("`", modifiers: .control)
    }

    @ViewBuilder
    private var wideToolbar: some View {
                if let tab = workspace.selectedTab {
                    if tab.isMarkdown {
                        Button(workspace.markdownSource ? "Preview" : "Source",
                               systemImage: workspace.markdownSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") {
                            workspace.markdownSource.toggle()
                        }
                        .help(workspace.markdownSource ? "Show the rendered Markdown" : "Show the Markdown source")
                    }
                    if tab.isComparison, !isNarrow {
                        Button(workspace.inlineDiffs ? "Side by Side" : "Inline",
                               systemImage: workspace.inlineDiffs ? "rectangle.split.2x1" : "rectangle.stack") {
                            workspace.inlineDiffs.toggle()
                        }
                        .help(workspace.inlineDiffs ? "Show side by side" : "Show inline")
                    }
                    if tab.kind == .file, let problems = workspace.diagnostics[tab.path], problems.contains(where: { $0.severity != .hint }) {
                        ProblemsButton(workspace: workspace, path: tab.path, problems: problems, theme: theme, fontSize: settings.fontSize)
                    }
                    claudeMenu(for: tab)
                    Button("Find in File", systemImage: "text.magnifyingglass", action: workspace.findInFile)
                        .keyboardShortcut("f", modifiers: .command)
                }
                Button("Go to File", systemImage: "doc.text.magnifyingglass") { workspace.showingQuickOpen = true }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Terminal", systemImage: "terminal", action: onTerminal)
                    .keyboardShortcut("`", modifiers: .control)
    }

    @ViewBuilder
    private func claudeMenu(for tab: EditorWorkspace.Tab) -> some View {
        Menu("Ask Claude", systemImage: "sparkles") {
            switch tab.kind {
            case .file:
                Button("Ask Claude About This File", systemImage: "doc.text") { workspace.askAboutFile(tab.path) }
                if let change = workspace.explorer.change(for: tab.path) {
                    Button("Ask Claude to Review This Change", systemImage: "plusminus") { workspace.reviewChange(change, scope: .head) }
                    Button("Open Changes", systemImage: "arrow.left.arrow.right") { workspace.open(.diff(change, .head), path: tab.path, pinned: true) }
                }
            case .diff(let change, let scope):
                Button("Ask Claude to Review This Change", systemImage: "plusminus") { workspace.reviewChange(change, scope: scope) }
                Button("Ask Claude About This File", systemImage: "doc.text") { workspace.askAboutFile(tab.path) }
                Button("Open File", systemImage: "doc.text") { workspace.open(.file, path: tab.path, pinned: true) }
            case .commit(let commit):
                Button("Ask Claude to Review This Commit", systemImage: "arrow.triangle.branch") { workspace.reviewCommit(commit) }
            case .commitFile(let commit, _):
                Button("Ask Claude to Review This Commit", systemImage: "arrow.triangle.branch") { workspace.reviewCommit(commit) }
                Button("Ask Claude About This File", systemImage: "doc.text") { workspace.askAboutFile(tab.path) }
                Button("Open File", systemImage: "doc.text") { workspace.open(.file, path: tab.path, pinned: true) }
                Button("Show Full Commit", systemImage: "text.alignleft") { workspace.open(.commit(commit), path: commit.sha, pinned: true) }
            }
            Divider()
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = tab.path }
        }
    }
}

// MARK: - Tabs

private struct TabStrip: View {
    @ObservedObject var workspace: EditorWorkspace
    let theme: TerminalTheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(workspace.tabs) { tab in
                    let selected = tab.id == workspace.selectedTabID
                    HStack(spacing: 6) {
                        if case .commit = tab.kind {
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.caption).foregroundStyle(.secondary)
                        } else {
                            FileIcon(name: (tab.path as NSString).lastPathComponent)
                        }
                        let problems = tab.kind == .file ? (workspace.diagnostics[tab.path] ?? []).filter { $0.severity <= .warning } : []
                        let worst = problems.map(\.severity).min()
                        Text(tab.title)
                            .italic(tab.isPreview)
                            .lineLimit(1)
                            .frame(maxWidth: 220)
                            .foregroundStyle(Color(uiColor: worst.map { theme.problemColor($0) } ?? theme.editorForeground).opacity(selected ? 1 : 0.65))
                        // VS Code's tab decoration: how many errors and warnings.
                        if let worst {
                            Text("\(problems.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color(uiColor: theme.problemColor(worst)))
                        }
                        Button {
                            workspace.close(tab)
                        } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close \(tab.title)")
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .foregroundStyle(Color(uiColor: theme.editorForeground).opacity(selected ? 1 : 0.65))
                    // Not into the safe area: a colour background at the top edge otherwise runs
                    // up under the navigation bar, a column above each tab (the "band" on device).
                    .background(Color(uiColor: selected ? theme.editorBackground : theme.editorChrome(0.06)),
                                ignoresSafeAreaEdges: [])
                    .overlay(alignment: .top) {
                        if selected { Rectangle().fill(.tint).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { workspace.pin(tab) }
                    .onTapGesture { workspace.selectedTabID = tab.id }
                    // VoiceOver: one tab, a button (taps are gestures, which it can't see),
                    // its close button kept separate.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(spokenTitle(tab))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { workspace.selectedTabID = tab.id }
                    .contextMenu {
                        Button("Keep Open", systemImage: "pin") { workspace.pin(tab) }
                        Button("Close", systemImage: "xmark") { workspace.close(tab) }
                        Button("Close Others", systemImage: "xmark.square") {
                            for other in workspace.tabs where other.id != tab.id { workspace.close(other) }
                        }
                    }
                }
            }
        }
        .hidesTopScrollEdgeEffect()
        .background(Color(uiColor: theme.editorChrome(0.09)))
    }

    /// "main.ts, 2 problems" (errors and warnings) for VoiceOver.
    private func spokenTitle(_ tab: EditorWorkspace.Tab) -> String {
        guard tab.kind == .file else { return tab.title }
        let count = (workspace.diagnostics[tab.path] ?? []).filter { $0.severity <= .warning }.count
        return count == 0 ? tab.title : "\(tab.title), \(count) problem\(count == 1 ? "" : "s")"
    }
}

// MARK: - Tab content

private struct EditorTabView: View {
    let tab: EditorWorkspace.Tab
    let workspace: EditorWorkspace
    let theme: TerminalTheme
    let inline: Bool
    let markdownSource: Bool
    let fontSize: CGFloat
    let revision: Int
    let reveal: EditorWorkspace.Reveal?
    let findRequest: Int
    /// The language server's problems in this file (a file tab, shown line for line).
    let problems: [LanguageServer.Diagnostic]
    @EnvironmentObject private var settings: AppSettings
    /// The symbol whose card is showing.
    @State private var symbol: Symbols.Query?
    /// What was fetched from the host; restyled (theme, text size) without fetching again.
    @State private var source: Source?
    @State private var content: Content = .loading

    enum Source {
        case unified(String)
        case comparison(old: String?, new: String?)
        case file(String, marks: [Int: LineDiff.Mark])
        /// Markdown text, and its host images as data URLs by `src`.
        case markdown(String, images: [String: String])
        case image(UIImage)
        case message(String)
    }

    enum Content {
        case loading
        case text(CodeStyle.Styled)
        case sideBySide(CodeStyle.SideBySide)
        case markdown(String)
        case image(UIImage)
        case message(String)
    }

    var body: some View {
        Group {
            switch content {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let styled):
                CodeTextView(styled: styled, theme: theme, reveal: reveal, findRequest: findRequest, symbolPath: tab.path,
                             onSymbol: showSymbol, onFontStep: stepFontSize) { displayLines in
                    askAboutSelection(displayLines, lines: styled.lines)
                }
            case .sideBySide(let sides):
                SideBySideView(sides: sides, theme: theme, findRequest: findRequest, symbolPath: tab.path,
                               onSymbol: showSymbol, onFontStep: stepFontSize) { displayLines in
                    askAboutSelection(displayLines, lines: sides.right.lines)
                }
            case .markdown(let html):
                MarkdownView(html: html, path: tab.path, background: theme.editorBackground, fontSize: fontSize,
                             findRequest: findRequest, onFontStep: stepFontSize) { path in
                    workspace.openFile(path)
                }
            case .image(let image):
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1200)
                }
            case .message(let message):
                ContentUnavailableView(message, systemImage: "doc")
            }
        }
        .popover(item: $symbol, attachmentAnchor: .rect(.rect(symbol?.rect ?? .zero)), arrowEdge: .top) { query in
            SymbolCard(query: query, workspace: workspace, theme: theme, fontSize: fontSize)
        }
        .background(Color(uiColor: theme.editorBackground))
        .task(id: "\(inline) \(markdownSource) \(revision)") {
            source = await fetch()
            restyle()
            if case .file(let text, _)? = source, case .file = tab.kind {
                workspace.checkProblems(in: tab.path, text: text)
            }
            #if DEBUG
            if symbol == nil, case .file(let text, _)? = source, let (query, references) = EditorDebug.symbolQuery(path: tab.path, text: text) {
                try? await Task.sleep(for: .seconds(1))
                if references { workspace.findReferences(query) } else { symbol = query }
            }
            #endif
        }
        .onChange(of: theme.id) { restyle() }
        .onChange(of: fontSize) { restyle() }
        .onChange(of: problems) {
            restyle()
            #if DEBUG
            if symbol == nil, CommandLine.arguments.contains("-problemCard"),
               let first = problems.first(where: { $0.severity == .error }) ?? problems.first {
                showSymbol(Symbols.Hit(word: "x", rect: CGRect(x: 160, y: 240, width: 90, height: 20),
                                       line: first.line, character: first.character), .problems)
            }
            #endif
        }
    }

    /// A symbol tapped (docs card), ⌘-tapped (definition) or picked from the edit menu.
    private func showSymbol(_ hit: Symbols.Hit, _ action: CodeTextView.SymbolAction) {
        // A file shown as itself (lines match the file): a language server can be asked.
        var text: String?
        if case .file(let fileText, _)? = source, case .file = tab.kind { text = fileText }
        var query = Symbols.Query(hit: hit, path: tab.path, text: text, goDirectly: action == .definition)
        query.problems = problems.filter { $0.severity != .hint && $0.overlaps(line: hit.line, from: hit.character, to: hit.character + hit.word.utf16.count) }
        query.lookUp = action != .problems
        switch action {
        case .references: workspace.findReferences(query)
        case .docs, .definition, .problems: symbol = query
        }
    }

    /// Pinch: the app-wide text size, a point at a time (9–28, as in Settings).
    private func stepFontSize(_ step: Int) {
        let size = min(28, max(9, settings.fontSize + CGFloat(step)))
        guard size != settings.fontSize else { return }
        settings.fontSize = size
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Maps the selected display lines to a file and its line range, then hands it to Claude.
    private func askAboutSelection(_ displayLines: ClosedRange<Int>, lines: [CodeStyle.LineRef?]) {
        let refs = displayLines.compactMap { lines.indices.contains($0) ? lines[$0] : nil }
        guard let path = refs.first?.path else {
            workspace.askAboutFile(tab.path)
            return
        }
        let numbers = refs.filter { $0.path == path }.map(\.line)
        workspace.askAboutSelection(in: path, lines: numbers.min()!...numbers.max()!)
    }

    /// Styles `source` in the current theme and text size.
    private func restyle() {
        guard let source else { return }
        let root = workspace.explorer.root ?? ""
        switch source {
        case .unified(let diff):
            // A whole commit names its files in the patch; a single file's diff may not.
            var defaultPath: String? = tab.path
            if case .commit = tab.kind { defaultPath = nil }
            content = diff.isEmpty ? .message("No changes")
                : .text(CodeStyle.styledDiff(diff, root: root, defaultPath: defaultPath, theme: theme, fontSize: fontSize))
        case .comparison(let old, let new):
            content = .sideBySide(CodeStyle.sideBySide(old: old, new: new, path: tab.path, theme: theme, fontSize: fontSize))
        case .file(let text, let marks):
            content = .text(CodeStyle.numbered(text, path: tab.path, theme: theme, fontSize: fontSize, marks: marks, problems: problems))
        case .markdown(let text, let images):
            // The text size is applied by the view (a CSS variable), so a pinch needn't reload.
            var page = MarkdownRenderer.page(for: text, theme: theme)
            for (source, url) in images { page = page.replacingOccurrences(of: "src=\"\(source)\"", with: "src=\"\(url)\"") }
            content = .markdown(page)
        case .image(let image):
            content = .image(image)
        case .message(let message):
            content = .message(message)
        }
    }

    private func fetch() async -> Source {
        let explorer = workspace.explorer
        do {
            switch tab.kind {
            case .diff(let change, let scope):
                if inline { return .unified(try await explorer.diff(for: change, scope: scope)) }
                let revisions = explorer.revisions(for: change, scope: scope)
                return try await compare(old: revisions.old.map { (change.relativePath, $0) },
                                         new: revisions.new.map { (change.relativePath, $0) })
            case .commitFile(let commit, let file):
                if inline { return .unified(try await explorer.diff(for: file, in: commit)) }
                let parent = commit.parents.first
                return try await compare(old: file.letter == "A" ? nil : parent.map { (file.oldPath, .commit($0)) },
                                         new: file.letter == "D" ? nil : (file.path, .commit(commit.sha)))
            case .commit(let commit):
                return .unified(try await explorer.show(commit))
            case .file:
                switch try await explorer.fs.read(tab.path) {
                case .text(let text) where tab.isMarkdown && !markdownSource:
                    return .markdown(text, images: await hostImages(in: MarkdownRenderer.page(for: text, theme: theme)))
                case .text(let text):
                    return .file(text, marks: await changeMarks(for: text))
                case .image(let data):
                    return UIImage(data: data).map(Source.image) ?? .message("Can't show this image")
                case .binary(let size):
                    return .message("Binary file (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
                case .tooLarge(let size):
                    return .message("Too large to preview (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
                }
            }
        } catch {
            return .message(error.localizedDescription)
        }
    }

    /// Two versions side by side, each `(path from the repository root, revision)`; nil is a
    /// side the file doesn't exist on.
    private func compare(old: (String, ExplorerModel.Revision)?, new: (String, ExplorerModel.Revision)?) async throws -> Source {
        let explorer = workspace.explorer
        var before: RemoteFS.ReadResult?
        var after: RemoteFS.ReadResult?
        if let old { before = try await explorer.contents(of: old.0, at: old.1) }
        if let new { after = try await explorer.contents(of: new.0, at: new.1) }
        for result in [before, after] {
            switch result {
            case .tooLarge(let size)?:
                return .message("Too large to compare (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
            case .binary?:
                return .message("Binary file changed")
            default: break
            }
        }
        if case .image(let data)? = after ?? before {
            return UIImage(data: data).map(Source.image) ?? .message("Can't show this image")
        }
        func text(_ result: RemoteFS.ReadResult?) -> String? {
            if case .text(let text)? = result { text } else { nil }
        }
        guard before != nil || after != nil else { return .message("No changes") }
        return .comparison(old: text(before), new: text(after))
    }

    /// The page's relative images (on the host, which the web view can't reach), fetched as
    /// data URLs by their `src`. Web images load as usual.
    private func hostImages(in page: String) async -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: #"<img\b[^>]*?\ssrc="([^"]+)""#, options: .caseInsensitive)
        let ns = page as NSString
        var sources: [String] = []
        for match in pattern.matches(in: page, range: NSRange(location: 0, length: ns.length)) {
            let source = ns.substring(with: match.range(at: 1))
            if !source.contains("://"), !source.hasPrefix("data:"), !sources.contains(source) { sources.append(source) }
        }
        var images: [String: String] = [:]
        let folder = (tab.path as NSString).deletingLastPathComponent
        for source in sources.prefix(20) {
            var relative = source.replacingOccurrences(of: "&amp;", with: "&")
            relative = String(relative.prefix { $0 != "?" && $0 != "#" })
            relative = relative.removingPercentEncoding ?? relative
            // "/docs/x.png" is from the repository root, as on GitHub.
            let base = relative.hasPrefix("/") ? (workspace.explorer.root ?? "") : folder
            let path = ((base as NSString).appendingPathComponent(relative) as NSString).standardizingPath
            let ext = (path as NSString).pathExtension.lowercased()
            let data: Data
            switch try? await workspace.explorer.fs.read(path) {
            case .image(let bytes)?: data = bytes
            case .text(let svg)? where ext == "svg": data = Data(svg.utf8)
            default: continue
            }
            let mime = ext == "svg" ? "image/svg+xml" : ext == "jpg" ? "image/jpeg" : "image/" + ext
            images[source] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        return images
    }

    /// VS Code's gutter marks for a file with uncommitted changes: what differs from HEAD.
    private func changeMarks(for text: String) async -> [Int: LineDiff.Mark] {
        let explorer = workspace.explorer
        guard let change = explorer.change(for: tab.path) else { return [:] }
        let lines = LineDiff.lines(text)
        if change.letter == "U" || change.indexStatus == "A" {
            return Dictionary(uniqueKeysWithValues: lines.indices.map { ($0, LineDiff.Mark.added) })
        }
        guard case .text(let head)? = try? await explorer.contents(of: change.relativePath, at: .commit("HEAD")) else { return [:] }
        let old = LineDiff.lines(head)
        return await Task.detached { LineDiff.marks(LineDiff.align(old, lines), newCount: lines.count) }.value
    }
}

// MARK: - Styling

/// Turns files and diffs into highlighted text, with a map from each displayed line back to
/// a file and line (for "Ask Claude About Selection").
enum CodeStyle {
    struct LineRef {
        let path: String
        let line: Int
    }

    /// Code to show: its text, the line numbers beside it (kept separate so they stay put
    /// when the code scrolls sideways, and stay out of copies), each display line's source
    /// line, and where the changes are for the overview ruler.
    struct Styled {
        var text: NSAttributedString
        var gutter: NSAttributedString?
        var lines: [LineRef?]
        var overview: [OverviewMark] = []
        var lineHeight: CGFloat
    }

    /// A change (or a problem) at a display line, drawn in the overview ruler.
    struct OverviewMark {
        let line: Int
        let color: UIColor
        /// Problems take the ruler's right lane, changes the left, as in VS Code.
        var isProblem = false
    }

    /// Two versions of a file, row-aligned; the right side's lines map to the new version.
    struct SideBySide {
        let left: Styled
        let right: Styled
    }

    /// Fonts for the editor's text size (the terminal's, from Settings).
    struct Metrics {
        let font: UIFont
        let boldFont: UIFont
        let lineHeight: CGFloat
        /// Every line the same height, whatever fallback fonts it uses, so the sides of a
        /// side-by-side diff stay level.
        let paragraph: NSParagraphStyle

        init(size: CGFloat) {
            font = .monospacedSystemFont(ofSize: size, weight: .regular)
            boldFont = .monospacedSystemFont(ofSize: size, weight: .bold)
            lineHeight = ceil(font.lineHeight)
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            paragraph = style
        }
    }
    private static func base(_ theme: TerminalTheme, _ metrics: Metrics) -> [NSAttributedString.Key: Any] {
        [.font: metrics.font, .foregroundColor: theme.editorForeground, .paragraphStyle: metrics.paragraph]
    }

    private static func highlighted(_ text: String, path: String, theme: TerminalTheme, _ metrics: Metrics) -> NSMutableAttributedString {
        let body = NSMutableAttributedString(string: text, attributes: base(theme, metrics))
        let firstLine = text.prefix { $0 != "\n" }
        SyntaxHighlighter.apply(to: body, language: SyntaxHighlighter.language(forPath: path, firstLine: firstLine),
                                palette: theme.syntax, boldFont: metrics.boldFont)
        return body
    }

    /// "  12 ▍ ": the number, then a slot the layout manager draws change marks in.
    private static func gutter(_ number: Int?, width: Int, mark: LineDiff.Mark?, theme: TerminalTheme, _ metrics: Metrics) -> NSAttributedString {
        let digits = number.map(String.init) ?? ""
        var attributes = base(theme, metrics)
        attributes[.foregroundColor] = theme.editorGutter
        let label = NSMutableAttributedString(string: String(repeating: " ", count: width - digits.count) + digits + "   ",
                                              attributes: attributes)
        if let mark {
            let color = switch mark {
            case .added: theme.markAdded
            case .modified: theme.markModified
            case .deletedAbove, .deletedBelow: theme.markDeleted
            }
            label.addAttribute(.codeGutterMark, value: CodeMark(mark, color: color), range: NSRange(location: width + 1, length: 1))
        }
        return label
    }

    /// Syntax-highlighted text with a dimmed, right-aligned line-number gutter and, for a
    /// changed file, VS Code's change marks (`marks` by 0-based line), with the language
    /// server's problems underlined.
    static func numbered(_ text: String, path: String, theme: TerminalTheme, fontSize: CGFloat = 13,
                         marks: [Int: LineDiff.Mark] = [:], problems: [LanguageServer.Diagnostic] = []) -> Styled {
        let metrics = Metrics(size: fontSize)
        let body = highlighted(text, path: path, theme: theme, metrics)
        let problemMarks = underline(problems, in: body, theme: theme)
        let count = text.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let width = String(count).count
        let numbers = NSMutableAttributedString()
        let newline = NSAttributedString(string: "\n", attributes: base(theme, metrics))
        for index in 0..<count {
            if index > 0 { numbers.append(newline) }
            numbers.append(gutter(index + 1, width: width, mark: marks[index], theme: theme, metrics))
        }
        let overview = marks.map { line, mark in
            let color = switch mark {
            case .added: theme.markAdded
            case .modified: theme.markModified
            case .deletedAbove, .deletedBelow: theme.markDeleted
            }
            return OverviewMark(line: line, color: color)
        }
        return Styled(text: body, gutter: numbers, lines: (0..<count).map { LineRef(path: path, line: $0 + 1) },
                      overview: overview + problemMarks, lineHeight: metrics.lineHeight)
    }

    /// VS Code's squiggles: each problem's range marked for the layout manager to underline
    /// in its colour (unused code faded instead), less serious first so errors win where they
    /// overlap. Returns the ruler's ticks.
    private static func underline(_ problems: [LanguageServer.Diagnostic], in body: NSMutableAttributedString,
                                  theme: TerminalTheme) -> [OverviewMark] {
        guard !problems.isEmpty else { return [] }
        let text = body.string as NSString
        var lineStarts = [0]
        var search = NSRange(location: 0, length: text.length)
        while true {
            let newline = text.range(of: "\n", options: .literal, range: search)
            guard newline.location != NSNotFound else { break }
            lineStarts.append(newline.upperBound)
            search = NSRange(location: newline.upperBound, length: text.length - newline.upperBound)
        }
        func lineEnd(_ line: Int) -> Int { line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : text.length }
        func offset(_ line: Int, _ character: Int) -> Int {
            let line = min(max(line, 0), lineStarts.count - 1)
            return min(lineStarts[line] + max(character, 0), lineEnd(line))
        }
        var marks: [OverviewMark] = []
        for problem in problems.sorted(by: { $0.severity > $1.severity }) {
            var start = offset(problem.line, problem.character)
            var end = max(offset(problem.endLine, problem.endCharacter), start)
            let line = min(max(problem.line, 0), lineStarts.count - 1)
            // An empty range (a missing token) still gets a character's squiggle.
            if end == start {
                if start < lineEnd(line) { end = start + 1 } else if start > lineStarts[line] { start -= 1 }
            }
            let range = NSRange(location: start, length: end - start)
            if problem.severity == .hint {
                guard problem.unnecessary, range.length > 0 else { continue }
                body.enumerateAttribute(.foregroundColor, in: range) { value, run, _ in
                    let color = value as? UIColor ?? theme.editorForeground
                    body.addAttribute(.foregroundColor, value: color.withAlphaComponent(0.5), range: run)
                }
                continue
            }
            let color = theme.problemColor(problem.severity)
            if range.length > 0 {
                body.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color,
                                    .codeProblem: color], range: range)
            }
            marks.append(OverviewMark(line: line, color: color, isProblem: true))
        }
        return marks
    }

    /// The old version on the left, the new on the right, unchanged lines level with each
    /// other and fillers opposite added or removed ones, as in VS Code's diff editor.
    static func sideBySide(old: String?, new: String?, path: String, theme: TerminalTheme, fontSize: CGFloat = 13) -> SideBySide {
        let metrics = Metrics(size: fontSize)
        let oldLines = old.map(LineDiff.lines) ?? []
        let newLines = new.map(LineDiff.lines) ?? []
        let rows = LineDiff.align(oldLines, newLines)
        let width = String(max(oldLines.count, newLines.count, 1)).count

        func side(_ text: String?, _ lines: [Substring]) -> (NSAttributedString, [NSRange]) {
            let styled = highlighted(text ?? "", path: path, theme: theme, metrics)
            var ranges: [NSRange] = []
            var location = 0
            for line in lines {
                ranges.append(NSRange(location: location, length: line.utf16.count))
                location += line.utf16.count + 1
            }
            return (styled, ranges)
        }
        let (oldText, oldRanges) = side(old, oldLines)
        let (newText, newRanges) = side(new, newLines)
        let left = (code: NSMutableAttributedString(), gutter: NSMutableAttributedString())
        let right = (code: NSMutableAttributedString(), gutter: NSMutableAttributedString())
        let newline = NSAttributedString(string: "\n", attributes: base(theme, metrics))

        func append(_ line: Int?, from text: NSAttributedString, _ ranges: [NSRange],
                    to side: (code: NSMutableAttributedString, gutter: NSMutableAttributedString), changed: Bool, tint: UIColor) {
            let codeStart = side.code.length
            let gutterStart = side.gutter.length
            if codeStart > 0 {
                side.code.append(newline)
                side.gutter.append(newline)
            }
            side.gutter.append(gutter(line.map { $0 + 1 }, width: width, mark: nil, theme: theme, metrics))
            if let line { side.code.append(text.attributedSubstring(from: ranges[line])) }
            if changed {
                // Tint from the line's start (after the newline ending the previous one).
                let tint = line == nil ? theme.diffFiller : tint
                let codeFrom = codeStart == 0 ? 0 : codeStart + 1
                let gutterFrom = gutterStart == 0 ? 0 : gutterStart + 1
                side.code.addAttribute(.codeLineBackground, value: tint, range: NSRange(location: codeFrom, length: side.code.length - codeFrom))
                side.gutter.addAttribute(.codeLineBackground, value: tint, range: NSRange(location: gutterFrom, length: side.gutter.length - gutterFrom))
            }
        }
        var lines: [LineRef?] = []
        var overview: [OverviewMark] = []
        for (index, row) in rows.enumerated() {
            append(row.old, from: oldText, oldRanges, to: left, changed: row.changed, tint: theme.diffRemoved)
            append(row.new, from: newText, newRanges, to: right, changed: row.changed, tint: theme.diffAdded)
            lines.append(row.new.map { LineRef(path: path, line: $0 + 1) })
            if row.changed {
                let color = row.old == nil ? theme.markAdded : row.new == nil ? theme.markDeleted : theme.markModified
                overview.append(OverviewMark(line: index, color: color))
            }
        }
        return SideBySide(left: Styled(text: left.code, gutter: left.gutter, lines: lines.map { _ in nil }, lineHeight: metrics.lineHeight),
                          right: Styled(text: right.code, gutter: right.gutter, lines: lines, overview: overview,
                                        lineHeight: metrics.lineHeight))
    }

    /// Unified diff (one file, or a whole `git show`) with VS Code-like colouring, each line
    /// highlighted in its file's language. Lines map to the new file's line numbers.
    static func styledDiff(_ diff: String, root: String, defaultPath: String?, theme: TerminalTheme, fontSize: CGFloat = 13) -> Styled {
        let metrics = Metrics(size: fontSize)
        let result = NSMutableAttributedString()
        var lines: [LineRef?] = []
        var overview: [OverviewMark] = []
        let added = theme.diffAdded
        let removed = theme.diffRemoved
        var path = defaultPath
        var language = defaultPath.flatMap { SyntaxHighlighter.language(forPath: $0) }
        var newLine = 0
        var inHunk = false

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var attributes = base(theme, metrics)
            var ref: LineRef?
            if line.hasPrefix("diff ") {
                inHunk = false
                attributes[.foregroundColor] = theme.editorGutter
            } else if !inHunk, line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                // "+++ b/path" names the file; "--- a/path" covers deletions (+++ /dev/null).
                let name = line.dropFirst(4)
                if name != "/dev/null" {
                    let relative = name.hasPrefix("a/") || name.hasPrefix("b/") ? String(name.dropFirst(2)) : String(name)
                    path = root.isEmpty ? relative : root + "/" + relative
                    language = SyntaxHighlighter.language(forPath: relative)
                }
                attributes[.foregroundColor] = theme.editorGutter
            } else if line.hasPrefix("@@") {
                inHunk = true
                newLine = Self.hunkStart(line) ?? 1
                attributes[.foregroundColor] = theme.diffHunk
            } else if inHunk, let path, line.hasPrefix("+") || line.hasPrefix(" ") {
                ref = LineRef(path: path, line: newLine)
                newLine += 1
                if line.hasPrefix("+") {
                    attributes[.codeLineBackground] = added
                    overview.append(OverviewMark(line: lines.count, color: theme.markAdded))
                }
            } else if inHunk, let path, line.hasPrefix("-") {
                ref = LineRef(path: path, line: newLine)
                attributes[.codeLineBackground] = removed
                overview.append(OverviewMark(line: lines.count, color: theme.markDeleted))
            } else if !inHunk {
                attributes[.foregroundColor] = theme.editorGutter   // commit header, stats
            }
            let start = result.length
            result.append(NSAttributedString(string: String(line) + "\n", attributes: attributes))
            lines.append(ref)
            if ref != nil, line.utf16.count > 1 {
                SyntaxHighlighter.apply(to: result, range: NSRange(location: start + 1, length: line.utf16.count - 1),
                                        language: language, palette: theme.syntax, boldFont: metrics.boldFont)
            }
        }
        return Styled(text: result, lines: lines, overview: overview, lineHeight: metrics.lineHeight)
    }

    /// The new-file start line of a hunk header: "@@ -a,b +c,d @@" → c.
    private static func hunkStart(_ header: Substring) -> Int? {
        guard let plus = header.firstIndex(of: "+") else { return nil }
        let digits = header[header.index(after: plus)...].prefix { $0.isNumber }
        return Int(digits)
    }
}

// MARK: - Text view

/// Read-only, selectable code that stays fast for large files. Lines don't wrap: a horizontal
/// scroll view holds a text view as wide as the longest line, which scrolls vertically itself.
/// (A UITextView only draws text within its own width, so it can't scroll sideways on its own:
/// text past its bounds came out blank.) The edit menu offers "Ask Claude About Selection" with
/// the selected display lines (0-based).
struct CodeTextView: UIViewRepresentable {
    let styled: CodeStyle.Styled
    let theme: TerminalTheme
    var reveal: EditorWorkspace.Reveal?
    var findRequest = 0
    /// The file shown, so symbols are looked up as its language.
    var symbolPath: String?
    var onSymbol: ((Symbols.Hit, SymbolAction) -> Void)?
    var onFontStep: ((Int) -> Void)?
    var onAskClaude: ((ClosedRange<Int>) -> Void)?

    /// `problems`: a tap on an underlined problem that isn't on a name.
    enum SymbolAction { case docs, definition, references, problems }

    func makeUIView(context: Context) -> CodeScrollView {
        let view = CodeScrollView()
        view.textView.delegate = context.coordinator
        context.coordinator.findRequest = findRequest
        return view
    }

    func updateUIView(_ view: CodeScrollView, context: Context) {
        context.coordinator.onAskClaude = onAskClaude
        view.pinch.onStep = onFontStep
        view.symbolPath = symbolPath
        view.onSymbol = onSymbol
        view.show(styled, theme: theme)
        if let reveal, context.coordinator.revealed != reveal.id {
            context.coordinator.revealed = reveal.id
            // After layout, so there are bounds to scroll within.
            DispatchQueue.main.async { view.reveal(line: reveal.line, column: reveal.column, length: reveal.length) }
        }
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.textView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onAskClaude: ((ClosedRange<Int>) -> Void)?
        var revealed: UUID?
        var findRequest = 0

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, let onAskClaude else { return nil }
            let lines = Self.displayLines(textView.text as NSString, range)
            let ask = UIAction(title: "Ask Claude About Selection", image: UIImage(systemName: "sparkles")) { _ in
                onAskClaude(lines)
            }
            let symbols = (textView.superview as? CodeScrollView)?.symbolActions(for: range) ?? []
            return UIMenu(children: symbols + [ask] + suggestedActions)
        }

        /// 0-based display lines covered by `range`.
        static func displayLines(_ text: NSString, _ range: NSRange) -> ClosedRange<Int> {
            func line(at location: Int) -> Int {
                var count = 0
                var search = NSRange(location: 0, length: min(location, text.length))
                while true {
                    let newline = text.range(of: "\n", options: [], range: search)
                    guard newline.location != NSNotFound else { return count }
                    count += 1
                    search = NSRange(location: newline.location + 1, length: search.upperBound - newline.location - 1)
                }
            }
            let first = line(at: range.location)
            return first...max(first, line(at: max(range.location, range.upperBound - 1)))
        }
    }

    /// Scrolls sideways; its text view is as wide as the longest line and scrolls vertically.
    /// The line numbers are a second text view pinned to the left edge (kept level with the
    /// code), and an overview ruler on the right shows where the changes are; tap or drag it
    /// to jump there.
    final class CodeScrollView: UIScrollView {
        let textView = CodeScrollView.makeTextView()
        let pinch = FontPinch()
        /// Symbol lookups: the file's path (for its language) and where to send taps.
        var symbolPath: String?
        var onSymbol: ((Symbols.Hit, SymbolAction) -> Void)?
        /// The view the card's anchor rect is relative to (the side-by-side container).
        weak var anchorView: UIView?
        private let symbolTap = UITapGestureRecognizer()
        private let simultaneous = SimultaneousGestures()
        private let gutterView = CodeScrollView.makeTextView()
        private let ruler = OverviewRuler()
        private var shown: NSAttributedString?
        private var lineWidth: CGFloat = 0
        private var gutterWidth: CGFloat = 0
        private var lineHeight: CGFloat = 16
        private var matchColor = UIColor.systemYellow.withAlphaComponent(0.4)
        private weak var flash: UIView?
        private var offsetObservation: NSKeyValueObservation?
        private static let codeInsets = UIEdgeInsets(top: 12, left: 8, bottom: 24, right: 24 + OverviewRuler.width)

        /// TextKit 1 with a layout manager that draws full-width line tints and change marks.
        private static func makeTextView() -> UITextView {
            let storage = NSTextStorage()
            let layoutManager = CodeLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true
            container.lineBreakMode = .byClipping
            layoutManager.addTextContainer(container)
            let view = UITextView(frame: .zero, textContainer: container)
            view.isEditable = false
            view.isSelectable = true
            view.backgroundColor = .clear
            view.textContainerInset = codeInsets
            view.dataDetectorTypes = []
            view.showsHorizontalScrollIndicator = false
            view.isFindInteractionEnabled = true
            if #available(iOS 26.0, *) { view.topEdgeEffect.isHidden = true }
            return view
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            if #available(iOS 26.0, *) { topEdgeEffect.isHidden = true }
            alwaysBounceHorizontal = false
            alwaysBounceVertical = false
            isDirectionalLockEnabled = true
            showsVerticalScrollIndicator = false
            gutterView.isUserInteractionEnabled = false
            gutterView.isFindInteractionEnabled = false
            gutterView.showsVerticalScrollIndicator = false
            addSubview(textView)
            addSubview(gutterView)
            addSubview(ruler)
            ruler.onSeek = { [weak self] fraction in self?.seek(to: fraction) }
            pinch.attach(to: self)
            symbolTap.addTarget(self, action: #selector(symbolTapped(_:)))
            symbolTap.delegate = simultaneous
            textView.addGestureRecognizer(symbolTap)
            offsetObservation = textView.observe(\.contentOffset) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.codeDidScroll() }
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func show(_ styled: CodeStyle.Styled, theme: TerminalTheme) {
            ruler.marks = styled.overview
            ruler.colors = (theme.editorChrome(0.06).withAlphaComponent(0.85), theme.editorForeground.withAlphaComponent(0.14))
            ruler.isHidden = styled.overview.isEmpty
            textView.showsVerticalScrollIndicator = styled.overview.isEmpty
            gutterView.backgroundColor = theme.editorBackground
            matchColor = theme.matchHighlight
            guard shown !== styled.text else { return setNeedsLayout() }
            // Restyled (theme, text size): keep the same line at the top.
            let oldLineHeight = shown == nil ? nil : lineHeight
            let topLine = (textView.contentOffset.y + textView.adjustedContentInset.top) / (oldLineHeight ?? 1)
            shown = styled.text
            let padding = 2 * textView.textContainer.lineFragmentPadding
            if let gutter = styled.gutter {
                gutterView.isHidden = false
                gutterView.textContainerInset = UIEdgeInsets(top: Self.codeInsets.top, left: 8, bottom: Self.codeInsets.bottom, right: 0)
                gutterWidth = CodeTextView.unwrappedWidth(gutter) + 8 + padding
                gutterView.attributedText = gutter
            } else {
                gutterView.isHidden = true
                gutterWidth = 0
            }
            var insets = Self.codeInsets
            insets.left += gutterWidth
            textView.textContainerInset = insets
            lineWidth = CodeTextView.unwrappedWidth(styled.text) + insets.left + insets.right + padding
            textView.attributedText = styled.text
            lineHeight = styled.lineHeight
            setNeedsLayout()
            if oldLineHeight != nil {
                layoutIfNeeded()
                textView.layoutManager.ensureLayout(for: textView.textContainer)
                let maxY = max(textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom, -textView.adjustedContentInset.top)
                let y = min(topLine * lineHeight - textView.adjustedContentInset.top, maxY)
                textView.setContentOffset(CGPoint(x: 0, y: max(y, -textView.adjustedContentInset.top)), animated: false)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let width = max(bounds.width, lineWidth)
            let frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            if textView.frame != frame { textView.frame = frame }
            contentSize = CGSize(width: width, height: bounds.height)
            // Pinned to the visible left and right edges as the code scrolls sideways.
            gutterView.frame = CGRect(x: contentOffset.x, y: 0, width: gutterWidth, height: bounds.height)
            ruler.frame = CGRect(x: contentOffset.x + bounds.width - OverviewRuler.width, y: 0, width: OverviewRuler.width, height: bounds.height)
            codeDidScroll()
        }

        /// The height the ruler stands for: all the code, or the view if the code is shorter
        /// (so a short file's ticks sit beside their lines).
        private var rulerSpan: CGFloat { max(textView.contentSize.height, textView.bounds.height, 1) }

        /// Keeps the line numbers level with the code and the ruler current.
        private func codeDidScroll() {
            let y = textView.contentOffset.y
            if gutterView.contentOffset.y != y { gutterView.contentOffset = CGPoint(x: 0, y: y) }
            let span = rulerSpan
            ruler.lineScale = (Self.codeInsets.top / span, lineHeight / span)
            ruler.viewport = (y / span, textView.bounds.height / span)
        }

        // MARK: Symbols

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // A double tap selects a word; don't also show its card.
            for case let tap as UITapGestureRecognizer in textView.gestureRecognizers ?? [] where tap.numberOfTapsRequired == 2 {
                symbolTap.require(toFail: tap)
            }
        }

        /// Tap on a name: its docs card. ⌘-tap: straight to its definition.
        @objc private func symbolTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let onSymbol, let symbolPath else { return }
            let point = gesture.location(in: textView)
            let inContainer = CGPoint(x: point.x - textView.textContainerInset.left, y: point.y - textView.textContainerInset.top)
            let layoutManager = textView.layoutManager
            let glyph = layoutManager.glyphIndex(for: inContainer, in: textView.textContainer)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer)
            guard glyphRect.insetBy(dx: -2, dy: -2).contains(inContainer) else { return }
            let text = textView.text as NSString
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            if let range = Symbols.word(at: index, in: text, path: symbolPath) {
                onSymbol(hit(range), gesture.modifierFlags.contains(.command) ? .definition : .docs)
            } else if index < textView.textStorage.length, textView.textStorage.attribute(.codeProblem, at: index, effectiveRange: nil) != nil {
                onSymbol(hit(NSRange(location: index, length: 1)), .problems)
            }
        }

        /// Edit-menu items for a selected name.
        func symbolActions(for range: NSRange) -> [UIMenuElement] {
            let text = textView.text as NSString
            guard let onSymbol, let symbolPath, let word = Symbols.word(at: range.location, in: text, path: symbolPath),
                  word == range else { return [] }
            let hit = hit(range)
            return [
                UIAction(title: "Go to Definition", image: UIImage(systemName: "arrow.turn.down.right")) { _ in onSymbol(hit, .definition) },
                UIAction(title: "Find All References", image: UIImage(systemName: "text.magnifyingglass")) { _ in onSymbol(hit, .references) },
                UIAction(title: "Show Docs", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in onSymbol(hit, .docs) },
            ]
        }

        /// The name in `range`, with its place on screen and its line and column.
        private func hit(_ range: NSRange) -> Symbols.Hit {
            let text = textView.text as NSString
            var line = 0
            var lineStart = 0
            while true {
                let newline = text.range(of: "\n", options: [], range: NSRange(location: lineStart, length: range.location - lineStart))
                guard newline.location != NSNotFound else { break }
                line += 1
                lineStart = newline.location + 1
            }
            return Symbols.Hit(word: text.substring(with: range), rect: anchorRect(for: range), line: line, character: range.location - lineStart)
        }

        /// Where `range` is, relative to the visible area of the anchor view.
        private func anchorRect(for range: NSRange) -> CGRect {
            let layoutManager = textView.layoutManager
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top
            let anchor = anchorView ?? self
            var result = textView.convert(rect, to: anchor)
            result.origin.x -= anchor.bounds.origin.x
            result.origin.y -= anchor.bounds.origin.y
            return result
        }

        /// Scrolls `line` (1-based) a third of the way down, brings the match into view
        /// sideways and flashes it.
        func reveal(line: Int, column: Int, length: Int) {
            let text = textView.text as NSString
            var start = 0
            var remaining = line - 1
            while remaining > 0 {
                let newline = text.range(of: "\n", options: [], range: NSRange(location: start, length: text.length - start))
                guard newline.location != NSNotFound else { break }
                start = newline.location + 1
                remaining -= 1
            }
            let location = min(start + column, text.length)
            let range = NSRange(location: location, length: min(max(length, 1), text.length - location))
            layoutIfNeeded()
            let layoutManager = textView.layoutManager
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: range.upperBound))
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
            rect.origin.x += textView.textContainerInset.left
            rect.origin.y += textView.textContainerInset.top

            // The text view's contentSize can lag behind a freshly set text, so take the height
            // from the layout itself.
            layoutManager.ensureLayout(for: textView.textContainer)
            textView.layoutIfNeeded()
            let insets = textView.textContainerInset
            let height = max(textView.contentSize.height, layoutManager.usedRect(for: textView.textContainer).height + insets.top + insets.bottom)
            let maxY = max(height - textView.bounds.height, 0)
            textView.setContentOffset(CGPoint(x: 0, y: min(max(rect.minY - textView.bounds.height / 3, 0), maxY)), animated: false)
            // Sideways only as far as needed to show the match (from its start if it's wide).
            let left = contentOffset.x + gutterWidth
            let right = contentOffset.x + bounds.width - OverviewRuler.width
            var x = contentOffset.x
            if rect.maxX + 24 > right { x = min(rect.maxX + 24 - (bounds.width - OverviewRuler.width), rect.minX - gutterWidth - 24) }
            if rect.minX < left { x = rect.minX - gutterWidth - 24 }
            x = min(max(x, 0), max(contentSize.width - bounds.width, 0))
            if x != contentOffset.x { setContentOffset(CGPoint(x: x, y: 0), animated: false) }

            flash?.removeFromSuperview()
            let marker = UIView(frame: rect.insetBy(dx: -2, dy: 0))
            marker.backgroundColor = matchColor
            marker.layer.cornerRadius = 3
            marker.isUserInteractionEnabled = false
            textView.addSubview(marker)
            flash = marker
            UIView.animate(withDuration: 0.6, delay: 2.5, options: []) { marker.alpha = 0 } completion: { _ in
                marker.removeFromSuperview()
            }
        }

        /// Scrolls so `fraction` of the way down the ruler is in the middle of the view.
        private func seek(to fraction: CGFloat) {
            let maxY = max(textView.contentSize.height - textView.bounds.height, 0)
            let y = min(max(fraction * rulerSpan - textView.bounds.height / 2, 0), maxY)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: y), animated: false)
        }

        /// Drags on the ruler move through the file rather than scroll the view sideways.
        override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            if gesture === panGestureRecognizer, !ruler.isHidden, ruler.frame.insetBy(dx: -6, dy: 0).contains(gesture.location(in: self)) {
                return false
            }
            return super.gestureRecognizerShouldBegin(gesture)
        }
    }

    /// The longest line's width; monospaced, so columns × character width (tabs as 4).
    static func unwrappedWidth(_ text: NSAttributedString) -> CGFloat {
        let font = text.length > 0 ? (text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) : nil
        let column = ("0" as NSString).size(withAttributes: [.font: font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
        var longest = 0
        for line in text.string.split(separator: "\n", omittingEmptySubsequences: false) {
            longest = max(longest, line.utf16.count + line.filter { $0 == "\t" }.count * 3)
        }
        return CGFloat(longest + 1) * column
    }
}

// MARK: - Side by side

/// Two code views, old and new, scrolling together both ways. Selecting on the new side offers
/// "Ask Claude About Selection".
struct SideBySideView: UIViewRepresentable {
    let sides: CodeStyle.SideBySide
    let theme: TerminalTheme
    var findRequest = 0
    var symbolPath: String?
    var onSymbol: ((Symbols.Hit, CodeTextView.SymbolAction) -> Void)?
    var onFontStep: ((Int) -> Void)?
    var onAskClaude: ((ClosedRange<Int>) -> Void)?

    func makeUIView(context: Context) -> Container {
        let view = Container()
        for side in [view.left, view.right] {
            side.delegate = context.coordinator
            side.textView.delegate = context.coordinator
        }
        context.coordinator.container = view
        context.coordinator.findRequest = findRequest
        return view
    }

    func updateUIView(_ view: Container, context: Context) {
        context.coordinator.onAskClaude = onAskClaude
        view.left.pinch.onStep = onFontStep
        view.right.pinch.onStep = onFontStep
        for side in [view.left, view.right] {
            side.symbolPath = symbolPath
            side.onSymbol = onSymbol
            side.anchorView = view
        }
        view.divider.backgroundColor = theme.editorChrome(0.14)
        view.left.show(sides.left, theme: theme)
        view.right.show(sides.right, theme: theme)
        if context.coordinator.findRequest != findRequest {
            context.coordinator.findRequest = findRequest
            view.right.textView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Container: UIView {
        let left = CodeTextView.CodeScrollView()
        let right = CodeTextView.CodeScrollView()
        let divider = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            left.showsHorizontalScrollIndicator = false
            [left, right, divider].forEach(addSubview)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let half = (bounds.width / 2).rounded()
            left.frame = CGRect(x: 0, y: 0, width: half, height: bounds.height)
            divider.frame = CGRect(x: half, y: 0, width: 1, height: bounds.height)
            right.frame = CGRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var container: Container?
        var onAskClaude: ((ClosedRange<Int>) -> Void)?
        var findRequest = 0
        private var syncing = false

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !syncing, let container else { return }
            syncing = true
            defer { syncing = false }
            let pairs: [(UIScrollView, UIScrollView)] = [
                (container.left.textView, container.right.textView), (container.right.textView, container.left.textView),
                (container.left, container.right), (container.right, container.left),
            ]
            guard let other = pairs.first(where: { $0.0 === scrollView })?.1 else { return }
            if scrollView is UITextView {
                let maxY = max(0, other.contentSize.height - other.bounds.height)
                other.contentOffset = CGPoint(x: other.contentOffset.x, y: min(max(scrollView.contentOffset.y, 0), maxY))
            } else {
                let maxX = max(0, other.contentSize.width - other.bounds.width)
                other.contentOffset = CGPoint(x: min(max(scrollView.contentOffset.x, 0), maxX), y: other.contentOffset.y)
            }
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let symbols = (textView.superview as? CodeTextView.CodeScrollView)?.symbolActions(for: range) ?? []
            guard let onAskClaude, textView === container?.right.textView else {
                return symbols.isEmpty ? nil : UIMenu(children: symbols + suggestedActions)
            }
            let lines = CodeTextView.Coordinator.displayLines(textView.text as NSString, range)
            let ask = UIAction(title: "Ask Claude About Selection", image: UIImage(systemName: "sparkles")) { _ in
                onAskClaude(lines)
            }
            return UIMenu(children: symbols + [ask] + suggestedActions)
        }
    }
}

// MARK: - Pinch

/// Pinch to change the text size: a step per 18% spread or squeeze since the last step, as in
/// the terminal (measuring from the last step stops jitter flipping the size back and forth).
final class FontPinch: NSObject {
    var onStep: ((Int) -> Void)?
    private var anchor: CGFloat = 1
    private static let step: CGFloat = 1.18

    func attach(to view: UIView) {
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            anchor = gesture.scale
        case .changed:
            if gesture.scale >= anchor * Self.step {
                anchor = gesture.scale
                onStep?(1)
            } else if gesture.scale <= anchor / Self.step {
                anchor = gesture.scale
                onStep?(-1)
            }
        default:
            break
        }
    }
}

// MARK: - Overview ruler

/// VS Code's overview ruler: a strip down the right edge with a tick for each change at its
/// place in the file, and a box for the part on screen. Tap or drag to jump.
final class OverviewRuler: UIView {
    static let width: CGFloat = 14
    var marks: [CodeStyle.OverviewMark] = [] { didSet { setNeedsDisplay() } }
    /// Where line 0 starts and how tall a line is, as fractions of the ruler.
    var lineScale: (CGFloat, CGFloat) = (0, 0.01) {
        didSet { if lineScale != oldValue { setNeedsDisplay() } }
    }
    /// Background, and the visible-region box.
    var colors: (UIColor, UIColor) = (.clear, .clear) { didSet { setNeedsDisplay() } }
    /// Top and height of the visible region, as fractions of the whole.
    var viewport: (CGFloat, CGFloat) = (0, 1) {
        didSet { if viewport != oldValue { setNeedsDisplay() } }
    }
    var onSeek: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(seek(_:))))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(seek(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func seek(_ gesture: UIGestureRecognizer) {
        guard bounds.height > 0 else { return }
        onSeek?(min(max(gesture.location(in: self).y / bounds.height, 0), 1))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        colors.0.setFill()
        context.fill(bounds)
        let height = bounds.height
        colors.1.setFill()
        context.fill(CGRect(x: 0, y: viewport.0 * height, width: bounds.width, height: max(viewport.1 * height, 6)))
        let tick = max(lineScale.1 * height, 2)
        // Two lanes when there are both changes and problems: changes left, problems right.
        let lanes = marks.contains(where: \.isProblem) && marks.contains(where: { !$0.isProblem })
        let half = (bounds.width - 6) / 2
        for mark in marks.sorted(by: { !$0.isProblem && $1.isProblem }) {
            mark.color.setFill()
            let x: CGFloat = lanes && mark.isProblem ? 3 + half + 1 : 3
            let width = lanes ? half - 1 : bounds.width - 6
            context.fill(CGRect(x: x, y: (lineScale.0 + CGFloat(mark.line) * lineScale.1) * height, width: width,
                                height: mark.isProblem ? max(tick, 3) : tick))
        }
    }
}

// MARK: - Line tints and change marks

extension NSAttributedString.Key {
    /// A UIColor filling the whole width of the lines it covers (diff tints).
    static let codeLineBackground = NSAttributedString.Key("AgentTermCodeLineBackground")
    /// A CodeMark drawn over the gutter character it covers.
    static let codeGutterMark = NSAttributedString.Key("AgentTermCodeGutterMark")
    /// A problem's colour: its underline is drawn as a squiggle.
    static let codeProblem = NSAttributedString.Key("AgentTermCodeProblem")
}

final class CodeMark: NSObject {
    let kind: LineDiff.Mark
    let color: UIColor

    init(_ kind: LineDiff.Mark, color: UIColor) {
        self.kind = kind
        self.color = color
    }
}

/// Draws `.codeLineBackground` across the full line (an ordinary background colour stops at
/// the text), VS Code's change marks (a bar for added or modified lines, a wedge where lines
/// were deleted) and problems' squiggly underlines.
final class CodeLayoutManager: NSLayoutManager {
    override func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat,
                                lineFragmentRect: CGRect, lineFragmentGlyphRange: NSRange, containerOrigin: CGPoint) {
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let storage = textStorage, characters.location < storage.length,
              let color = storage.attribute(.codeProblem, at: characters.location, effectiveRange: nil) as? UIColor,
              let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil),
              let context = UIGraphicsGetCurrentContext() else {
            return super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineType, baselineOffset: baselineOffset,
                                       lineFragmentRect: lineFragmentRect, lineFragmentGlyphRange: lineFragmentGlyphRange,
                                       containerOrigin: containerOrigin)
        }
        let rect = boundingRect(forGlyphRange: glyphRange, in: container).offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
        let y = lineFragmentRect.maxY + containerOrigin.y - 2
        // A zigzag in steps on a fixed grid, so pieces of one underline (split at colour
        // changes) join up.
        let step: CGFloat = 2
        var x = (rect.minX / step).rounded(.down) * step
        let end = max(rect.maxX, x + step * 2)
        context.saveGState()
        color.setStroke()
        context.setLineWidth(1)
        context.move(to: CGPoint(x: x, y: y + (Int(x / step) % 2 == 0 ? 1 : -1)))
        while x < end {
            x += step
            context.addLine(to: CGPoint(x: x, y: y + (Int(x / step) % 2 == 0 ? 1 : -1)))
        }
        context.strokePath()
        context.restoreGState()
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let context = UIGraphicsGetCurrentContext() else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.codeLineBackground, in: characters) { value, range, _ in
            guard let color = value as? UIColor else { return }
            color.setFill()
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { rect, _, _, _, _ in
                context.fill(CGRect(x: 0, y: rect.minY + origin.y, width: rect.maxX + origin.x + 200, height: rect.height))
            }
        }

        storage.enumerateAttribute(.codeGutterMark, in: characters) { value, range, _ in
            guard let mark = value as? CodeMark else { return }
            let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0, let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) else { return }
            let line = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let slot = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
            mark.color.setFill()
            switch mark.kind {
            case .added, .modified:
                context.fill(CGRect(x: slot.midX - 1.5, y: line.minY, width: 3, height: line.height))
            case .deletedAbove, .deletedBelow:
                let y = mark.kind == .deletedAbove ? line.minY : line.maxY
                context.move(to: CGPoint(x: slot.midX - 2, y: y - 4))
                context.addLine(to: CGPoint(x: slot.midX + 3, y: y))
                context.addLine(to: CGPoint(x: slot.midX - 2, y: y + 4))
                context.closePath()
                context.fillPath()
            }
        }
    }
}

extension View {
    /// Turns off iPadOS 26's fade under the navigation bar for scroll views in this view.
    @ViewBuilder
    func hidesTopScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
