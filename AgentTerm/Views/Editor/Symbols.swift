import SwiftUI

/// Code navigation without a language server: definitions found by searching the folder for
/// each language's declaration forms (ripgrep, else grep), docs taken from the comment above a
/// declaration (or a Python docstring under it), references by whole-word search. Like VS Code
/// for a language with no extension installed, a little smarter; nothing to install.
enum Symbols {
    /// A name tapped or selected in a code view: where it is on screen and in the text.
    struct Hit {
        let word: String
        /// In the code view's visible coordinates (where to anchor the card).
        let rect: CGRect
        /// 0-based line and UTF-16 column of the name's start.
        let line: Int
        let character: Int
    }

    /// A symbol to show a card for.
    struct Query: Identifiable {
        let id = UUID()
        let hit: Hit
        /// The file it was found in.
        let path: String
        /// The file's text when the view shows the file itself (line for line), so a language
        /// server can be asked; nil for diffs and other views.
        var text: String?
        /// ⌘-tap: go straight to a single definition.
        var goDirectly = false
        /// The language server's problems under the tap, shown first on the card.
        var problems: [LanguageServer.Diagnostic] = []
        /// False for a tap on a problem that isn't on a name: the card shows just the problem.
        var lookUp = true
        var word: String { hit.word }
        var rect: CGRect { hit.rect }
    }

    struct Definition: Identifiable {
        let path: String
        let relativePath: String
        /// 1-based line, and the name's UTF-16 column in it.
        let line: Int
        let column: Int
        /// The declaration (its first lines, without the body).
        let signature: String
        /// The doc comment, as Markdown-ish text.
        let docs: String
        /// Lower sorts first: this file, then types and functions, then properties and locals.
        let rank: Int
        var id: String { "\(path):\(line)" }
    }

    /// The files a language's symbols live in, and how its declarations look (`NAME` stands
    /// for the symbol).
    struct Family {
        let globs: [String]
        let patterns: [String]
        /// Comment starts for docs above a declaration.
        let lineComments: [String]
        var hasDocstrings = false
    }

    static func family(forPath path: String) -> Family {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":
            return Family(globs: ["*.swift"], patterns: [
                #"\b(?:func|class|struct|enum|protocol|actor|typealias|associatedtype|macro|extension)\s+NAME\b"#,
                #"\b(?:var|let)\s+NAME\b"#,
                #"\bcase\s+(?:[A-Za-z_]\w*(?:\([^)]*\))?\s*,\s*)*NAME\b"#,
            ], lineComments: ["///", "//"])
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts":
            return Family(globs: ["*.js", "*.mjs", "*.cjs", "*.jsx", "*.ts", "*.tsx", "*.mts", "*.cts"], patterns: [
                #"\b(?:function\*?|class|interface|type|enum|namespace)\s+NAME\b"#,
                #"\b(?:const|let|var)\s+NAME\b"#,
                #"^\s*(?:(?:export|public|private|protected|static|readonly|async|get|set|abstract|override|declare)\s+)*NAME\s*(?:<[^>]*>)?\s*\([^)]*\)?\s*(?::[^={]*)?\{?\s*$"#,
                #"^\s*(?:(?:public|private|protected|static|readonly|declare)\s+)*NAME\s*[?!]?\s*:"#,
            ], lineComments: ["//"])
        case "py", "pyi":
            return Family(globs: ["*.py", "*.pyi"], patterns: [
                #"^\s*(?:async\s+)?def\s+NAME\b"#, #"^\s*class\s+NAME\b"#, #"^\s*NAME\s*(?::[^=]*)?=[^=]"#,
            ], lineComments: ["#"], hasDocstrings: true)
        case "go":
            return Family(globs: ["*.go"], patterns: [
                #"\bfunc\s+(?:\([^)]*\)\s*)?NAME\b"#, #"\btype\s+NAME\b"#, #"\b(?:var|const)\s+NAME\b"#, #"^\s*NAME\s*(?:,\s*\w+\s*)*:?="#,
            ], lineComments: ["//"])
        case "rs":
            return Family(globs: ["*.rs"], patterns: [
                #"\b(?:fn|struct|enum|trait|type|const|static|mod|union)\s+NAME\b"#, #"\bmacro_rules!\s*NAME\b"#,
                #"\blet\s+(?:mut\s+)?NAME\b"#, #"^\s*(?:pub(?:\([^)]*\))?\s+)?NAME\s*:"#,
            ], lineComments: ["///", "//!", "//"])
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm":
            return Family(globs: ["*.c", "*.h", "*.cc", "*.cpp", "*.cxx", "*.hpp", "*.hh", "*.m", "*.mm"], patterns: [
                #"#\s*define\s+NAME\b"#, #"\b(?:struct|class|enum|union|namespace)\s+NAME\b"#, #"\btypedef\b.*\bNAME\s*;"#,
                #"^[A-Za-z_][\w\s\*&<>:,]*[\s\*&]NAME\s*\([^;]*$"#, #"^[-+]\s*\([^)]*\)\s*NAME\b"#, #"@(?:interface|protocol|implementation)\s+NAME\b"#,
                #"@property\b.*\bNAME\s*;"#,
            ], lineComments: ["///", "//"])
        case "java", "kt", "kts", "scala", "groovy", "cs":
            return Family(globs: ["*.java", "*.kt", "*.kts", "*.scala", "*.groovy", "*.cs"], patterns: [
                #"\b(?:class|interface|enum|record|object|struct|trait|fun|val|var|def)\s+NAME\b"#,
                #"^\s*(?:(?:public|private|protected|internal|static|final|abstract|override|virtual|async|readonly|sealed|open|suspend|inline|synchronized)\s+)*[\w<>\[\],\.?]+\s+NAME\s*[\({=;]"#,
            ], lineComments: ["///", "//"])
        case "rb":
            return Family(globs: ["*.rb"], patterns: [
                #"\bdef\s+(?:self\.)?NAME\b"#, #"\b(?:class|module)\s+NAME\b"#, #"\battr_\w+\b.*:NAME\b"#, #"^\s*NAME\s*="#,
            ], lineComments: ["#"])
        case "php":
            return Family(globs: ["*.php"], patterns: [
                #"\bfunction\s+NAME\b"#, #"\b(?:class|interface|trait|enum)\s+NAME\b"#, #"\bconst\s+NAME\b"#,
            ], lineComments: ["//", "#"])
        case "sh", "bash", "zsh", "ksh":
            return Family(globs: ["*.sh", "*.bash", "*.zsh", "*.ksh"], patterns: [
                #"^\s*(?:function\s+)?NAME\s*\(\)"#, #"^\s*function\s+NAME\b"#, #"^\s*(?:export\s+|local\s+|readonly\s+)?NAME="#,
            ], lineComments: ["#"])
        default:
            return Family(globs: [], patterns: [
                #"\b(?:func|function|def|fn|sub|proc|class|struct|enum|interface|trait|type|let|var|const|val)\s+NAME\b"#,
            ], lineComments: ["//", "#"])
        }
    }

    /// Identifier characters (with `$` for JavaScript and PHP).
    static func isIdentifier(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || character == 95 /* _ */ || character == 36 /* $ */
    }

    /// The identifier at `index` in `text`, if there is one worth looking up (not a number or
    /// a keyword of the file's language).
    static func word(at index: Int, in text: NSString, path: String) -> NSRange? {
        guard index >= 0, index < text.length, isIdentifier(text.character(at: index)) else { return nil }
        var start = index
        var end = index + 1
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isIdentifier(text.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        let word = text.substring(with: range)
        if let first = word.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { return nil }
        if let language = SyntaxHighlighter.language(forPath: path),
           language.keywords.contains(word) || language.control.contains(word) || language.constants.contains(word) {
            return nil
        }
        return range
    }

    // MARK: Lookup

    /// Declarations of `word` in the folder, best first, with their signatures and docs.
    @MainActor
    static func definitions(of word: String, from path: String, explorer: ExplorerModel) async -> [Definition] {
        guard let root = explorer.root else { return [] }
        let family = family(forPath: path)
        let name = NSRegularExpression.escapedPattern(for: word)
        let pattern = family.patterns.map { $0.replacingOccurrences(of: "NAME", with: name) }.joined(separator: "|")
        let output = (try? await explorer.fs.run(#"""
            cd "$P" || exit
            set -f
            if command -v rg >/dev/null; then
                set -- --null --line-number --no-heading --with-filename --color never --hidden -g '!.git' --max-count 20 --max-columns 600
                for g in $GLOBS; do set -- "$@" -g "$g"; done
                rg "$@" -e "$PATTERN" -- . | head -n 60
            else
                set -- -rnIH --null -P --exclude-dir=.git
                for g in $GLOBS; do set -- "$@" --include="$g"; done
                grep "$@" -e "$PATTERN" -- . | head -n 60
            fi
            """#, ["P": root, "PATTERN": pattern, "GLOBS": family.globs.joined(separator: " ")])) ?? ""

        struct Hit { let relative: String; let line: Int; let text: String }
        var hits: [Hit] = []
        for line in output.split(separator: "\n") {
            guard let nul = line.firstIndex(of: "\0") else { continue }
            var relative = String(line[..<nul])
            if relative.hasPrefix("./") { relative.removeFirst(2) }
            let rest = line[line.index(after: nul)...]
            guard let colon = rest.firstIndex(of: ":"), let number = Int(rest[..<colon]) else { continue }
            hits.append(Hit(relative: relative, line: number, text: String(rest[rest.index(after: colon)...])))
        }
        guard !hits.isEmpty else { return [] }
        hits = Array(hits.prefix(25))

        // The lines around each hit, in one round trip, for signatures and docs.
        let list = hits.map { "\($0.line)\t\($0.relative)" }.joined(separator: "\n")
        let excerpts = (try? await explorer.fs.run(#"""
            cd "$P" || exit
            printf '%s\n' "$LIST" | while IFS="$(printf '\t')" read -r l f; do
                a=$((l > 40 ? l - 40 : 1))
                printf '\036%s\t%s\t%s\n' "$l" "$a" "$f"
                sed -n "${a},$((l + 40))p" -- "$f"
            done
            """#, ["P": root, "LIST": list])) ?? ""
        var context: [String: (first: Int, lines: [Substring])] = [:]
        for chunk in excerpts.split(separator: "\u{1e}") {
            let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false)
            let header = lines.first?.split(separator: "\t", maxSplits: 2).map(String.init) ?? []
            guard header.count == 3, let line = Int(header[0]), let first = Int(header[1]) else { continue }
            context["\(header[2]):\(line)"] = (first, Array(lines.dropFirst()))
        }

        let wordPattern = try? NSRegularExpression(pattern: "(?<![\\w$])" + name + "(?![\\w$])")
        return hits.map { hit in
            let column = wordPattern?.firstMatch(in: hit.text, range: NSRange(location: 0, length: (hit.text as NSString).length))?.range.location ?? 0
            var signature = hit.text.trimmingCharacters(in: .whitespaces)
            var docs = ""
            if let (first, lines) = context["\(hit.relative):\(hit.line)"] {
                let index = hit.line - first
                if lines.indices.contains(index) {
                    signature = Self.signature(lines, from: index)
                    docs = Self.docs(lines, at: index, family: family)
                }
            }
            let fullPath = root + "/" + hit.relative
            var rank = Self.kindRank(hit.text, word: word)
            if fullPath == path { rank -= 10 }
            return Definition(path: fullPath, relativePath: hit.relative, line: hit.line, column: column,
                              signature: signature, docs: docs, rank: rank)
        }
        .sorted { ($0.rank, $0.relativePath, $0.line) < ($1.rank, $1.relativePath, $1.line) }
    }

    /// The text of some 1-based lines, in one round trip (for listing locations).
    @MainActor
    static func lines(_ places: [(path: String, line: Int)], explorer: ExplorerModel) async -> [String] {
        guard !places.isEmpty else { return [] }
        let list = places.map { "\($0.line)\t\($0.path)" }.joined(separator: "\n")
        let output = (try? await explorer.fs.run(#"""
            printf '%s\n' "$LIST" | while IFS="$(printf '\t')" read -r l f; do
                printf '\036'
                sed -n "${l}p" -- "$f" 2>/dev/null
            done
            """#, ["LIST": list])) ?? ""
        var texts = output.split(separator: "\u{1e}", omittingEmptySubsequences: false).dropFirst()
            .map { String($0.hasSuffix("\n") ? $0.dropLast() : $0) }
        while texts.count < places.count { texts.append("") }
        return texts
    }

    /// A path for display: relative to the folder when inside it, else with ~ for home.
    @MainActor
    static func displayPath(_ path: String, explorer: ExplorerModel) -> String {
        if let root = explorer.root, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        if let range = path.range(of: #"^/home/[^/]+"#, options: .regularExpression) { return "~" + path[range.upperBound...] }
        if path.hasPrefix("/root/") { return "~" + path.dropFirst(5) }
        return path
    }

    /// Types and functions before properties before locals.
    private static func kindRank(_ line: String, word: String) -> Int {
        let types = ["class ", "struct ", "enum ", "protocol ", "interface ", "trait ", "type ", "typealias ", "actor ", "module ", "namespace ", "record ", "object "]
        let functions = ["func ", "function ", "def ", "fn ", "fun ", "sub "]
        if types.contains(where: { line.contains($0 + word) }) { return 0 }
        if functions.contains(where: { line.contains($0) }) { return 1 }
        if line.first?.isWhitespace == false { return 2 }   // top level
        return 3
    }

    /// The declaration from its first line until its body starts (or a few lines), without
    /// the opening brace.
    private static func signature(_ lines: [Substring], from index: Int) -> String {
        var result: [String] = []
        var depth = 0
        for line in lines[index...].prefix(8) {
            var text = String(line)
            for character in text {
                if "([<".contains(character) { depth += 1 }
                if ")]>".contains(character) { depth -= 1 }
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let opensBody = trimmed.hasSuffix("{") || (trimmed.hasSuffix(":") && depth <= 0 && result.isEmpty == false)
            if trimmed.hasSuffix("{"), let brace = text.lastIndex(of: "{") { text = String(text[..<brace]) }
            result.append(text)
            if opensBody || (depth <= 0 && !trimmed.hasSuffix(",") && !trimmed.hasSuffix("(")) { break }
        }
        // Common indentation off.
        let indent = result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        return result.map { String($0.dropFirst(indent)) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Comment lines as paragraphs: a single line break is a soft wrap (as Markdown reads
    /// it); blank lines, list items and tags start new lines.
    private static func reflow(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let startsBlock = trimmed.isEmpty || trimmed.hasPrefix("-") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("@")
                || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") || trimmed.first?.isNumber == true && trimmed.contains(". ")
            if result.isEmpty {
                result = trimmed
            } else if trimmed.isEmpty {
                result += "\n\n"
            } else if startsBlock || result.hasSuffix("\n") {
                result += (result.hasSuffix("\n") ? "" : "\n") + trimmed
            } else {
                result += " " + trimmed
            }
        }
        return result
    }

    /// The comment block straight above the declaration (skipping attributes and decorators),
    /// or a Python docstring below it, with comment markers removed.
    private static func docs(_ lines: [Substring], at index: Int, family: Family) -> String {
        if family.hasDocstrings {
            var cursor = index
            while cursor < lines.count, !lines[cursor].trimmingCharacters(in: .whitespaces).hasSuffix(":") { cursor += 1 }
            cursor += 1
            if cursor < lines.count {
                let first = lines[cursor].trimmingCharacters(in: .whitespaces)
                for quote in ["\"\"\"", "'''"] where first.hasPrefix(quote) {
                    var body = String(first.dropFirst(3))
                    if let end = body.range(of: quote) { return String(body[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
                    var collected = [body]
                    for line in lines[(cursor + 1)...] {
                        body = line.trimmingCharacters(in: .whitespaces)
                        if let end = body.range(of: quote) {
                            collected.append(String(body[..<end.lowerBound]))
                            break
                        }
                        collected.append(body)
                    }
                    return reflow(collected).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        var collected: [String] = []
        var cursor = index - 1
        var inBlock = false
        while cursor >= 0 {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if inBlock {
                if trimmed.hasPrefix("/*") {
                    let text = trimmed.drop { $0 == "/" || $0 == "*" || $0 == "!" }.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { collected.append(text) }
                    inBlock = false
                } else {
                    collected.append(String(trimmed.drop { $0 == "*" }).trimmingCharacters(in: .whitespaces))
                }
            } else if trimmed.hasSuffix("*/") {
                let text = String(trimmed.dropLast(2))
                if text.hasPrefix("/*") {
                    collected.append(text.drop { $0 == "/" || $0 == "*" || $0 == "!" }.trimmingCharacters(in: .whitespaces))
                } else {
                    inBlock = true
                    let inner = text.drop { $0 == "*" }.trimmingCharacters(in: .whitespaces)
                    if !inner.isEmpty { collected.append(inner) }
                }
            } else if let marker = family.lineComments.first(where: { trimmed.hasPrefix($0) }),
                      !trimmed.hasPrefix("#!"), !trimmed.hasPrefix("#include"), !trimmed.hasPrefix("#define"), !trimmed.hasPrefix("#if"),
                      !trimmed.hasPrefix("// MARK:") {
                var text = String(trimmed.dropFirst(marker.count))
                if text.hasPrefix(" ") { text.removeFirst() }
                collected.append(text)
            } else if trimmed.hasPrefix("@") || trimmed.hasPrefix("#[") || trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                // Attributes, decorators, annotations: between the docs and the declaration.
            } else {
                break
            }
            cursor -= 1
        }
        var text = reflow(Array(collected.reversed()))
        // DocC / JSDoc / Javadoc tags, readably.
        for (tag, label) in [("- Parameter ", "**Parameter** "), ("- Parameters:", "**Parameters:**"), ("- Returns:", "**Returns:**"),
                             ("- Throws:", "**Throws:**"), ("@param ", "**Parameter** "), ("@returns ", "**Returns:** "),
                             ("@return ", "**Returns:** "), ("@throws ", "**Throws:** "), ("@deprecated", "**Deprecated**")] {
            text = text.replacingOccurrences(of: tag, with: label)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Card

/// VS Code's hover, as a popover: the declaration, its docs, where it is, and what to do next.
/// Asks the language server for TypeScript/JavaScript and Python files shown as themselves;
/// otherwise (or if the server can't answer) searches the folder.
struct SymbolCard: View {
    let query: Symbols.Query
    let workspace: EditorWorkspace
    let theme: TerminalTheme
    let fontSize: CGFloat
    @State private var result: Result?
    @State private var selected = 0
    @Environment(\.dismiss) private var dismiss

    /// What the card shows: a signature and docs, and where the symbol is declared.
    struct Result {
        var signature = ""
        var docs = ""
        /// The file whose language the signature is highlighted in.
        var signaturePath: String
        var definitions: [Place]
        /// "TypeScript", "Pyright", or nil (found by searching).
        var server: String?
        /// The search-based lookup's own signature and docs per definition.
        var perDefinition: [(signature: String, docs: String)]?
        /// The docs are a man page or other plain text: shown monospaced.
        var preformatted = false
    }

    struct Place: Identifiable {
        let path: String
        let display: String
        /// 1-based line, UTF-16 column.
        let line: Int
        let column: Int
        let preview: String
        var id: String { "\(path):\(line):\(column)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !query.problems.isEmpty {
                problemList
                if query.lookUp { Divider() }
            }
            if !query.lookUp {
                EmptyView()
            } else if let result {
                if result.signature.isEmpty, result.docs.isEmpty, result.definitions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(query.word).font(.system(size: fontSize, design: .monospaced).weight(.semibold))
                        Text("No declaration found in this folder (library and framework symbols have no source here).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(14)
                } else {
                    details(result)
                    if result.definitions.count > 1 { others(result.definitions) }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking up \(query.word)…").foregroundStyle(.secondary)
                }
                .padding(14)
            }
            Divider()
            actions
        }
        // A set width: the card's height is measured at the width it's shown at (long docs
        // came out clipped top and bottom in a popover free to widen).
        .frame(width: Device.isPhone ? nil : 520)
        // In an iPhone sheet: from the top, not centred in it.
        .frame(maxHeight: Device.isPhone ? .infinity : nil, alignment: .top)
        .background(Color(uiColor: theme.editorChrome(0.06)))
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        // iPhone: a sheet (a popover there is narrower than the card).
        .presentationCompactAdaptation(Device.isPhone ? .sheet : .popover)
        .presentationDetents(Device.isPhone ? [.medium, .large] : [.large])
        .task { if query.lookUp { await lookUp() } }
    }

    /// The problems under the tap, as VS Code's hover shows them above the docs.
    private var problemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(query.problems.enumerated()), id: \.offset) { _, problem in
                    ProblemRow(problem: problem, theme: theme, fontSize: fontSize)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lookUp() async {
        let explorer = workspace.explorer
        if let text = query.text, let server = workspace.languageServer(for: query.path) {
            do {
                let hover = try await server.hover(path: query.path, text: text, line: query.hit.line, character: query.hit.character)
                let locations = try await server.definition(path: query.path, text: text, line: query.hit.line, character: query.hit.character)
                if query.goDirectly, locations.count == 1 {
                    return go(Place(path: locations[0].path, display: "", line: locations[0].line + 1, column: locations[0].character, preview: ""))
                }
                if hover != nil || !locations.isEmpty {
                    let previews = await Symbols.lines(locations.map { ($0.path, $0.line + 1) }, explorer: explorer)
                    let places = zip(locations, previews).map { location, preview in
                        Place(path: location.path, display: Symbols.displayPath(location.path, explorer: explorer),
                              line: location.line + 1, column: location.character, preview: preview.trimmingCharacters(in: .whitespaces))
                    }
                    result = Result(signature: hover?.signature ?? "", docs: hover?.docs ?? "", signaturePath: query.path,
                                    definitions: places, server: server.kind.displayName, preformatted: hover?.preformatted ?? false)
                    return
                }
            } catch {
                // Not installed on this host, or not answering: search instead (and start afresh next time).
                workspace.discardLanguageServer(for: query.path)
            }
        }
        let found = await Symbols.definitions(of: query.word, from: query.path, explorer: explorer)
        if query.goDirectly, found.count == 1 {
            return go(Place(path: found[0].path, display: "", line: found[0].line, column: found[0].column, preview: ""))
        }
        result = Result(signature: found.first?.signature ?? "", docs: found.first?.docs ?? "",
                        signaturePath: found.first?.path ?? query.path,
                        definitions: found.map { Place(path: $0.path, display: $0.relativePath, line: $0.line, column: $0.column,
                                                       preview: $0.signature.components(separatedBy: "\n").first ?? "") },
                        server: nil, perDefinition: found.map { ($0.signature, $0.docs) })
    }

    private func details(_ result: Result) -> some View {
        let index = min(selected, max(result.definitions.count - 1, 0))
        let signature = result.perDefinition.map { $0[index].signature } ?? result.signature
        let docs = result.perDefinition.map { $0[index].docs } ?? result.docs
        let path = result.perDefinition == nil ? result.signaturePath : result.definitions[index].path
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !signature.isEmpty {
                    Text(highlighted(signature, path: path))
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(uiColor: theme.editorBackground), in: RoundedRectangle(cornerRadius: 8))
                }
                if !docs.isEmpty, result.preformatted {
                    // A man page is laid out for 80 columns: scroll sideways rather than rewrap.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(docs)
                            .font(.system(size: max(fontSize - 2, 10), design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                } else if !docs.isEmpty {
                    Text(markdown(docs))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    if result.definitions.indices.contains(index) {
                        let place = result.definitions[index]
                        Button {
                            go(place)
                        } label: {
                            Label("\(place.display):\(place.line)", systemImage: "arrow.turn.down.right")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer(minLength: 4)
                    Text(result.server.map { "via \($0)" } ?? "found by search")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(14)
        }
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Other declarations, as VS Code's peek list.
    private func others(_ definitions: [Place]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            Text("\(definitions.count) DEFINITIONS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(definitions.enumerated()), id: \.element.id) { index, place in
                        Button {
                            selected = index
                        } label: {
                            HStack(spacing: 6) {
                                FileIcon(name: (place.path as NSString).lastPathComponent)
                                Text(place.preview).font(.caption.monospaced()).lineLimit(1)
                                Spacer(minLength: 6)
                                Text("\((place.path as NSString).lastPathComponent):\(place.line)")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 28)
                            .background(index == selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let result, !result.definitions.isEmpty {
                Button(Device.isPhone ? "Definition" : "Go to Definition", systemImage: "arrow.turn.down.right") {
                    go(result.definitions[min(selected, result.definitions.count - 1)])
                }
            }
            if query.lookUp {
                Button(Device.isPhone ? "References" : "Find All References", systemImage: "text.magnifyingglass") {
                    dismiss()
                    workspace.findReferences(query)
                }
            }
            Spacer()
            if !query.problems.isEmpty {
                Button("Fix with Claude", systemImage: "wand.and.sparkles") {
                    dismiss()
                    workspace.askToFix(query.problems, in: query.path)
                }
            } else {
                askClaude
            }
        }
        .font(.callout)
        .lineLimit(1)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var askClaude: some View {
        Button("Ask Claude", systemImage: "sparkles") {
            dismiss()
            let place = result.flatMap { $0.definitions.isEmpty ? nil : $0.definitions[min(selected, $0.definitions.count - 1)] }
            workspace.askAboutSymbol(query.word, in: place?.path ?? query.path, line: place?.line)
        }
    }

    private func go(_ place: Place) {
        dismiss()
        workspace.reveal(place.path, line: place.line, column: place.column, length: query.word.utf16.count)
    }

    private func highlighted(_ code: String, path: String) -> AttributedString {
        let text = NSMutableAttributedString(string: code, attributes: [.foregroundColor: theme.editorForeground])
        SyntaxHighlighter.apply(to: text, language: SyntaxHighlighter.language(forPath: path), palette: theme.syntax,
                                boldFont: .monospacedSystemFont(ofSize: fontSize, weight: .bold))
        return (try? AttributedString(text, including: \.uiKit)) ?? AttributedString(code)
    }

    private func markdown(_ docs: String) -> AttributedString {
        (try? AttributedString(markdown: docs, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(docs)
    }
}
