import SwiftUI

/// Search across the open folder, as VS Code's Search view: ripgrep on the host (grep when
/// it isn't installed), honouring .gitignore, with case/word/regex options and include and
/// exclude globs. Matches are highlighted here, so both tools give the same results.
@MainActor
final class SearchModel: ObservableObject {
    struct Match: Identifiable {
        /// Unique across all results ("path:index"), so list rows never mix files.
        let id: String
        /// 1-based line in the file.
        let line: Int
        /// The line, trimmed for display, and the matches within it.
        let preview: String
        let previewRanges: [NSRange]
        /// The first match, as a UTF-16 column and length in the full line (for revealing it).
        let column: Int
        let length: Int
    }

    struct FileResult: Identifiable {
        let path: String
        let relativePath: String
        let matches: [Match]
        var id: String { path }
        var name: String { (relativePath as NSString).lastPathComponent }
        var folder: String { (relativePath as NSString).deletingLastPathComponent }
    }

    @Published var query = "" { didSet { if query != oldValue, !showingReferences { scheduleSearch() } } }
    @Published var matchCase = false { didSet { scheduleSearch() } }
    @Published var wholeWord = false { didSet { scheduleSearch() } }
    @Published var regex = false { didSet { scheduleSearch() } }
    @Published var include = "" { didSet { if include != oldValue { scheduleSearch() } } }
    @Published var exclude = "" { didSet { if exclude != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [FileResult] = []
    @Published private(set) var isSearching = false
    @Published private(set) var summary: String?
    @Published private(set) var error: String?

    private let explorer: ExplorerModel
    private var task: Task<Void, Never>?
    /// Set while showing a language server's references (the query shows the name only).
    private var showingReferences = false
    /// More than this many matching lines and the rest are left out (as VS Code's limit).
    private static let lineLimit = 2000

    init(explorer: ExplorerModel) {
        self.explorer = explorer
    }

    /// Searches a moment after typing stops.
    func scheduleSearch(delay: Duration = .milliseconds(350)) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.search()
        }
    }

    func search() async {
        let query = query
        guard !query.isEmpty, let root = explorer.root else {
            results = []
            summary = nil
            error = nil
            return
        }
        isSearching = true
        defer { isSearching = false }
        let output: String
        do {
            output = try await explorer.fs.run(#"""
                cd "$P" || exit
                set -f
                trim() { printf %s "$1" | sed 's/^ *//;s/ *$//'; }
                if command -v rg >/dev/null; then
                    set -- --null --line-number --no-heading --with-filename --color never --hidden -g '!.git' --max-count 200 --max-columns 1000
                    [ -n "$CASE" ] || set -- "$@" -i
                    [ -n "$WORD" ] && set -- "$@" -w
                    [ -n "$REGEX" ] || set -- "$@" -F
                    IFS=,
                    for g in $INC; do g=$(trim "$g"); [ -n "$g" ] && set -- "$@" -g "$g"; done
                    for g in $EXC; do g=$(trim "$g"); [ -n "$g" ] && set -- "$@" -g "!$g"; done
                    unset IFS
                    rg "$@" -e "$Q" -- . | head -n 2001
                else
                    set -- -rnIH --null --exclude-dir=.git
                    [ -n "$CASE" ] || set -- "$@" -i
                    [ -n "$WORD" ] && set -- "$@" -w
                    if [ -n "$REGEX" ]; then set -- "$@" -E; else set -- "$@" -F; fi
                    IFS=,
                    for g in $INC; do g=$(trim "$g"); [ -n "$g" ] && set -- "$@" --include="$g"; done
                    for g in $EXC; do g=$(trim "$g"); [ -n "$g" ] && set -- "$@" --exclude="$g" --exclude-dir="$g"; done
                    unset IFS
                    grep "$@" -e "$Q" -- . | head -n 2001
                fi
                """#, ["P": root, "Q": query, "CASE": matchCase ? "1" : "", "WORD": wholeWord ? "1" : "",
                       "REGEX": regex ? "1" : "", "INC": include, "EXC": exclude])
        } catch {
            self.error = error.localizedDescription
            return
        }
        // A newer search has started (typing continued): drop this one.
        guard query == self.query else { return }
        error = nil
        parse(output, root: root)
    }

    private func parse(_ output: String, root: String) {
        let highlighter = matcher()
        var order: [String] = []
        var byFile: [String: [Match]] = [:]
        var count = 0
        // Each line: path NUL line-number ":" text.
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard count < Self.lineLimit, let nul = line.firstIndex(of: "\0") else { continue }
            var relative = String(line[..<nul])
            if relative.hasPrefix("./") { relative.removeFirst(2) }
            let rest = line[line.index(after: nul)...]
            guard let colon = rest.firstIndex(of: ":"), let number = Int(rest[..<colon]) else { continue }
            let text = String(rest[rest.index(after: colon)...])
            let ranges = highlighter(text)
            let (preview, previewRanges) = Self.preview(text, ranges)
            if byFile[relative] == nil { order.append(relative) }
            byFile[relative, default: []].append(Match(
                id: "\(relative):\(count)", line: number, preview: preview, previewRanges: previewRanges,
                column: ranges.first?.location ?? 0, length: ranges.first?.length ?? 0
            ))
            count += 1
        }
        // ripgrep searches files in parallel, so its order varies: sort by path as VS Code does.
        results = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { FileResult(path: root + "/" + $0, relativePath: $0, matches: (byFile[$0] ?? []).sorted { $0.line < $1.line }) }
        let files = results.count
        summary = count == 0 ? "No results"
            : "\(count)\(count >= Self.lineLimit ? "+" : "") result\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
                + (count >= Self.lineLimit ? " (showing the first \(Self.lineLimit))" : "")
    }

    /// Finds the matches in a line the way the search did (UTF-16 ranges).
    private func matcher() -> (String) -> [NSRange] {
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive]) else {
            return { _ in [] }
        }
        return { text in
            expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                .map(\.range).filter { $0.length > 0 }
        }
    }

    /// The line without its indentation, and cut to show the first match if it's long.
    private static func preview(_ text: String, _ ranges: [NSRange]) -> (String, [NSRange]) {
        let ns = text as NSString
        var start = 0
        while start < ns.length, let scalar = UnicodeScalar(ns.character(at: start)), CharacterSet.whitespaces.contains(scalar) {
            start += 1
        }
        var prefix = ""
        if let first = ranges.first, first.location - start > 60 {
            start = first.location - 40
            prefix = "…"
        }
        let preview = prefix + ns.substring(with: NSRange(location: start, length: max(min(ns.length - start, 240), 0)))
        let shift = start - (prefix as NSString).length
        let shifted = ranges.compactMap { range -> NSRange? in
            let moved = NSRange(location: range.location - shift, length: range.length)
            return moved.location >= 0 && moved.upperBound <= (preview as NSString).length ? moved : nil
        }
        return (preview, shifted)
    }

    /// Puts `word` in the box while a language server finds its references (no search).
    func prepareReferences(to word: String) {
        task?.cancel()
        showingReferences = true
        query = word
        showingReferences = false
        results = []
        summary = "Finding references…"
    }

    /// Shows a language server's references to `word` as the results.
    func showReferences(to word: String, at locations: [LanguageServer.Location], via server: String) async {
        prepareReferences(to: word)
        isSearching = true
        defer { isSearching = false }
        let texts = await Symbols.lines(locations.map { ($0.path, $0.line + 1) }, explorer: explorer)
        var order: [String] = []
        var byFile: [String: [Match]] = [:]
        for (index, (location, text)) in zip(locations, texts).enumerated() {
            let range = NSRange(location: location.character, length: max(location.length, word.utf16.count))
            let (preview, previewRanges) = Self.preview(text, [range])
            if byFile[location.path] == nil { order.append(location.path) }
            byFile[location.path, default: []].append(Match(
                id: "\(location.path):\(index)", line: location.line + 1, preview: preview, previewRanges: previewRanges,
                column: location.character, length: range.length
            ))
        }
        results = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { path in
            FileResult(path: path, relativePath: Symbols.displayPath(path, explorer: explorer),
                       matches: (byFile[path] ?? []).sorted { $0.line < $1.line })
        }
        error = nil
        summary = "\(locations.count) reference\(locations.count == 1 ? "" : "s") to \(word) in \(results.count) file\(results.count == 1 ? "" : "s") (\(server))"
    }

    // MARK: Quick open

    /// Every file in the folder (respecting .gitignore), for Go to File.
    func listFiles() async -> [String] {
        guard let root = explorer.root else { return [] }
        let output = (try? await explorer.fs.run(#"""
            cd "$P" || exit
            if command -v rg >/dev/null; then rg --files --hidden -g '!.git' | head -n 50000
            elif git rev-parse --git-dir >/dev/null 2>&1; then git ls-files -co --exclude-standard | head -n 50000
            else find . -type f -not -path '*/.git/*' | sed 's|^\./||' | head -n 50000
            fi
            """#, ["P": root])) ?? ""
        return output.split(separator: "\n").map(String.init).sorted()
    }

    /// VS Code-ish fuzzy match: the query's characters in order; contiguous runs, matches in
    /// the file name and at word starts score higher. Nil when it doesn't match.
    nonisolated static func fuzzyScore(_ path: String, query: String) -> Int? {
        let query = query.lowercased().filter { $0 != " " }
        guard !query.isEmpty else { return 0 }
        let candidate = Array(path.lowercased())
        let original = Array(path)
        let nameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        var score = 0
        var index = 0
        var previous = -2
        for character in query {
            guard let found = candidate[index...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previous + 1 { score += 5 }
            if found >= nameStart { score += 3 }
            if found == nameStart || found > 0 && "/_-. ".contains(original[found - 1]) || original[found].isUppercase {
                score += 4
            }
            previous = found
            index = found + 1
        }
        return score * 100 - path.count
    }
}

// MARK: - Search panel

struct SearchPanel: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var search: SearchModel
    @State private var showsGlobs = false
    @State private var collapsed: Set<String> = []
    @FocusState private var focused: Bool
    @Environment(\.editorTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { search.scheduleSearch(delay: .zero) }
                    toggle("Match Case", "textformat", $search.matchCase)
                    toggle("Match Whole Word", "character.textbox", $search.wholeWord)
                    toggle("Use Regular Expression", "asterisk", $search.regex)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    if search.isSearching {
                        ProgressView().controlSize(.small)
                    }
                    if let error = search.error {
                        Text(error).foregroundStyle(.red)
                    } else if let summary = search.summary {
                        Text(summary).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(showsGlobs ? "Hide Filters" : "Filters", systemImage: "line.3.horizontal.decrease.circle") {
                        withAnimation { showsGlobs.toggle() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .symbolVariant(search.include.isEmpty && search.exclude.isEmpty ? .none : .fill)
                    if !search.results.isEmpty {
                        Button(collapsed.isEmpty ? "Collapse All" : "Expand All",
                               systemImage: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical") {
                            collapsed = collapsed.isEmpty ? Set(search.results.map(\.id)) : []
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                .font(.caption)

                if showsGlobs {
                    globField("Files to include (e.g. *.swift, src/**)", $search.include)
                    globField("Files to exclude", $search.exclude)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { file in
                        fileRow(file)
                        if !collapsed.contains(file.id) {
                            ForEach(file.matches) { match in matchRow(match, in: file) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            if search.query.isEmpty { focused = true }
        }
    }

    private func toggle(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Button(title, systemImage: icon) { isOn.wrappedValue.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 28, height: 26)
            .foregroundStyle(isOn.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(isOn.wrappedValue ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            .help(title)
    }

    private func globField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func fileRow(_ file: SearchModel.FileResult) -> some View {
        Button {
            if collapsed.remove(file.id) == nil { collapsed.insert(file.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(collapsed.contains(file.id) ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                FileIcon(name: file.name)
                Text(file.name).lineLimit(1)
                Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(file.matches.count)")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.primary.opacity(0.1), in: Capsule())
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", systemImage: "doc.text") { workspace.open(.file, path: file.path, pinned: true) }
            Button("Ask Claude About This", systemImage: "sparkles") { workspace.askAboutFile(file.path) }
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
        }
    }

    private func matchRow(_ match: SearchModel.Match, in file: SearchModel.FileResult) -> some View {
        Button {
            workspace.reveal(file.path, line: match.line, column: match.column, length: match.length)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(match.line)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 26, alignment: .trailing)
                Text(highlighted(match))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 30)
            .padding(.trailing, 12)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Ask Claude About This Line", systemImage: "sparkles") {
                workspace.askAboutSelection(in: file.path, lines: match.line...match.line)
            }
            Button("Copy Line", systemImage: "doc.on.doc") { UIPasteboard.general.string = match.preview }
        }
    }

    private func highlighted(_ match: SearchModel.Match) -> AttributedString {
        var text = AttributedString(match.preview)
        let highlight = theme.map { Color(uiColor: $0.matchHighlight) } ?? .yellow.opacity(0.35)
        for range in match.previewRanges {
            guard let swiftRange = Range(range, in: match.preview),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: text),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = highlight
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

// MARK: - Go to File

/// ⌘P: type part of a file's path, pick it from the best matches.
struct QuickOpenView: View {
    @ObservedObject var workspace: EditorWorkspace
    @State private var query = ""
    @State private var files: [String]?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [String] {
        guard let files else { return [] }
        if query.isEmpty { return Array(files.prefix(60)) }
        return files.compactMap { path in SearchModel.fuzzyScore(path, query: query).map { (path, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
            .map(\.0)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("File name or path", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { if let first = matches.first { open(first) } }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
                List {
                    if files == nil {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    ForEach(matches, id: \.self) { path in
                        Button {
                            open(path)
                        } label: {
                            HStack(spacing: 8) {
                                FileIcon(name: (path as NSString).lastPathComponent)
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Go to File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            focused = true
            files = await workspace.search.listFiles()
        }
    }

    private func open(_ relative: String) {
        workspace.open(.file, path: (workspace.explorer.root ?? "") + "/" + relative)
        dismiss()
    }
}
