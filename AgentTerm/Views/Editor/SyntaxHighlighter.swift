import UIKit

/// A small, fast syntax highlighter for the editor, coloured by the theme's SyntaxPalette.
/// It's a single-pass lexer per language family rather than a full parser: good enough to read
/// code by, and quick on multi-megabyte files.
enum SyntaxHighlighter {
    enum Token {
        case comment, string, number, keyword, control, type, function, property, variable, heading, emphasis, tag
    }

    static func color(_ token: Token, in palette: SyntaxPalette) -> UIColor {
        switch token {
        case .comment: palette.comment
        case .string: palette.string
        case .number: palette.number
        case .keyword: palette.keyword
        case .control: palette.control
        case .type: palette.type
        case .function: palette.function
        case .property, .variable: palette.property
        case .tag: palette.tag
        case .heading: palette.heading
        case .emphasis: palette.emphasis
        }
    }

    /// Colours `text` in place (ranges are UTF-16, as NSAttributedString uses).
    static func apply(to text: NSMutableAttributedString, range: NSRange? = nil, language: Language?,
                      palette: SyntaxPalette, boldFont: UIFont) {
        guard let language else { return }
        let target = range ?? NSRange(location: 0, length: text.length)
        let source = (text.string as NSString).substring(with: target)
        for (token, tokenRange) in tokens(in: source, language: language) {
            let shifted = NSRange(location: tokenRange.location + target.location, length: tokenRange.length)
            text.addAttribute(.foregroundColor, value: color(token, in: palette), range: shifted)
            if token == .heading { text.addAttribute(.font, value: boldFont, range: shifted) }
        }
    }

    // MARK: Languages

    struct Language {
        enum Kind { case code, json, yaml, ini, markdown, markup, css }

        var kind: Kind = .code
        var keywords: Set<String> = []
        var control: Set<String> = []
        var constants: Set<String> = ["true", "false", "null", "nil"]
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var quotes: Set<Character> = ["\"", "'"]
        var tripleQuotes = false
        var multilineQuote: Character? = nil
        var caseInsensitive = false
        var capitalizedAreTypes = true
        var dollarVariables = false
    }

    private static let cControl: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "try", "catch", "finally", "throw", "throws"]

    static func language(forPath path: String, firstLine: Substring? = nil) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        switch name {
        case "dockerfile", "containerfile": return dockerfile
        case "makefile", "gnumakefile": return makefile
        case ".env", ".gitignore", ".dockerignore", ".editorconfig": return ini
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".bash_logout": return shell
        default: break
        }
        switch ext {
        case "swift": return swift
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts": return javascript
        case "py", "pyi": return python
        case "go": return go
        case "rs": return rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return c
        case "java", "kt", "kts", "scala", "groovy", "gradle": return java
        case "cs": return csharp
        case "rb": return ruby
        case "php": return php
        case "sh", "bash", "zsh", "fish", "ksh": return shell
        case "sql": return sql
        case "css", "scss", "less": return css
        case "json", "jsonc", "json5", "webmanifest": return json
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "env", "properties": return ini
        case "md", "markdown", "mdx": return markdown
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard", "vue": return markup
        default: break
        }
        if let first = firstLine, first.hasPrefix("#!") {
            if first.contains("python") { return python }
            if first.contains("node") || first.contains("deno") || first.contains("bun") { return javascript }
            if first.contains("ruby") { return ruby }
            return shell
        }
        return nil
    }

    static let swift = Language(
        keywords: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "init", "deinit", "self", "Self", "super", "static", "private", "fileprivate", "internal", "public", "open", "final", "override", "mutating", "nonmutating", "inout", "some", "any", "async", "await", "actor", "nonisolated", "lazy", "weak", "unowned", "typealias", "associatedtype", "subscript", "operator", "where", "in", "is", "as", "get", "set", "willSet", "didSet", "convenience", "required", "indirect", "true", "false", "nil", "rethrows"],
        control: cControl.union(["guard", "defer", "repeat", "fallthrough", "where", "throws"]),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], tripleQuotes: true)
    static let javascript = Language(
        keywords: ["const", "let", "var", "function", "class", "extends", "new", "this", "super", "import", "export", "from", "as", "async", "await", "yield", "typeof", "instanceof", "in", "of", "delete", "void", "static", "get", "set", "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "declare", "namespace", "abstract", "keyof", "true", "false", "null", "undefined"],
        control: cControl, lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineQuote: "`")
    static let python = Language(
        keywords: ["def", "class", "lambda", "import", "from", "as", "global", "nonlocal", "pass", "None", "True", "False", "and", "or", "not", "in", "is", "self", "async", "await", "del", "assert"],
        control: ["if", "elif", "else", "for", "while", "break", "continue", "return", "try", "except", "finally", "raise", "with", "yield", "match", "case"],
        lineComments: ["#"], tripleQuotes: true)
    static let go = Language(
        keywords: ["package", "import", "func", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "select", "range", "true", "false", "nil", "iota"],
        control: cControl.union(["fallthrough"]), lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineQuote: "`")
    static let rust = Language(
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "type", "mod", "use", "pub", "crate", "self", "Self", "super", "where", "as", "dyn", "ref", "move", "async", "await", "unsafe", "extern", "true", "false"],
        control: ["if", "else", "for", "while", "loop", "match", "break", "continue", "return", "in"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""])
    static let c = Language(
        keywords: ["int", "char", "float", "double", "void", "long", "short", "unsigned", "signed", "const", "static", "extern", "struct", "union", "enum", "typedef", "sizeof", "inline", "volatile", "auto", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "nullptr", "bool", "true", "false", "NULL", "@interface", "@implementation", "@end", "@property", "self", "nil", "YES", "NO"],
        control: cControl, lineComments: ["//"], blockComment: ("/*", "*/"))
    static let java = Language(
        keywords: ["class", "interface", "enum", "extends", "implements", "new", "this", "super", "import", "package", "public", "private", "protected", "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean", "char", "byte", "short", "var", "val", "fun", "object", "data", "sealed", "override", "open", "true", "false", "null", "when", "is", "in"],
        control: cControl, lineComments: ["//"], blockComment: ("/*", "*/"), tripleQuotes: true)
    static let csharp = Language(
        keywords: ["class", "struct", "interface", "enum", "record", "namespace", "using", "new", "this", "base", "public", "private", "protected", "internal", "static", "readonly", "const", "virtual", "override", "abstract", "sealed", "async", "await", "var", "void", "int", "string", "bool", "double", "decimal", "object", "get", "set", "init", "true", "false", "null", "is", "as", "in", "out", "ref"],
        control: cControl.union(["foreach", "yield"]), lineComments: ["//"], blockComment: ("/*", "*/"))
    static let ruby = Language(
        keywords: ["def", "class", "module", "end", "self", "nil", "true", "false", "require", "include", "extend", "attr_reader", "attr_accessor", "and", "or", "not", "lambda", "proc", "do", "then"],
        control: ["if", "elsif", "else", "unless", "case", "when", "while", "until", "for", "break", "next", "return", "begin", "rescue", "ensure", "raise", "yield"],
        lineComments: ["#"], dollarVariables: false)
    static let php = Language(
        keywords: ["function", "class", "interface", "trait", "extends", "implements", "new", "public", "private", "protected", "static", "const", "use", "namespace", "echo", "true", "false", "null", "array", "fn"],
        control: cControl.union(["foreach", "elseif"]), lineComments: ["//", "#"], blockComment: ("/*", "*/"), dollarVariables: true)
    static let shell = Language(
        keywords: ["function", "local", "export", "readonly", "declare", "echo", "printf", "cd", "source", "set", "unset", "true", "false", "sudo"],
        control: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "return", "exit", "break", "continue"],
        lineComments: ["#"], capitalizedAreTypes: false, dollarVariables: true)
    static let sql = Language(
        keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "index", "primary", "key", "foreign", "references", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "distinct", "union", "all", "case", "when", "then", "else", "end", "default", "unique", "constraint", "view", "with", "returning", "true", "false"],
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""], caseInsensitive: true, capitalizedAreTypes: false)
    static let dockerfile = Language(
        keywords: ["from", "run", "cmd", "label", "expose", "env", "add", "copy", "entrypoint", "volume", "user", "workdir", "arg", "onbuild", "stopsignal", "healthcheck", "shell", "as"],
        lineComments: ["#"], caseInsensitive: true, capitalizedAreTypes: false, dollarVariables: true)
    static let makefile = Language(lineComments: ["#"], capitalizedAreTypes: false, dollarVariables: true)
    static let css = Language(kind: .css, blockComment: ("/*", "*/"))
    static let json = Language(kind: .json, quotes: ["\""])
    static let yaml = Language(kind: .yaml, lineComments: ["#"])
    static let ini = Language(kind: .ini, lineComments: ["#", ";"])
    static let markdown = Language(kind: .markdown)
    static let markup = Language(kind: .markup)

    // MARK: Lexer

    static func tokens(in source: String, language: Language) -> [(Token, NSRange)] {
        let chars = Array(source.utf16)
        switch language.kind {
        case .code: return codeTokens(chars, language)
        case .json: return jsonTokens(chars)
        case .yaml, .ini: return keyValueTokens(chars, language)
        case .markdown: return markdownTokens(source)
        case .markup: return markupTokens(chars)
        case .css: return cssTokens(chars)
        }
    }

    private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }

    private static func isIdent(_ c: UInt16) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    private static func matches(_ chars: [UInt16], _ i: Int, _ s: String) -> Bool {
        let u = Array(s.utf16)
        guard i + u.count <= chars.count else { return false }
        for k in 0..<u.count where chars[i + k] != u[k] { return false }
        return true
    }

    private static func endOfLine(_ chars: [UInt16], _ i: Int) -> Int {
        var j = i
        while j < chars.count, chars[j] != 10 { j += 1 }
        return j
    }

    /// Index just past a string starting at `i` with `quote`; stops at a newline unless allowed.
    private static func endOfString(_ chars: [UInt16], _ i: Int, quote: UInt16, multiline: Bool) -> Int {
        var j = i + 1
        while j < chars.count {
            let c = chars[j]
            if c == 92 { j += 2; continue }           // backslash escape
            if c == quote { return j + 1 }
            if c == 10, !multiline { return j }
            j += 1
        }
        return chars.count
    }

    private static func codeTokens(_ chars: [UInt16], _ lang: Language) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        let quotes = Set(lang.quotes.compactMap { $0.utf16.first })
        let multiQuote = lang.multilineQuote?.utf16.first
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if lang.lineComments.contains(where: { matches(chars, i, $0) }) {
                let end = endOfLine(chars, i)
                out.append((.comment, NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            if let block = lang.blockComment, matches(chars, i, block.0) {
                var j = i + block.0.utf16.count
                while j < n, !matches(chars, j, block.1) { j += 1 }
                j = min(n, j + block.1.utf16.count)
                out.append((.comment, NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            if lang.tripleQuotes, matches(chars, i, "\"\"\"") || matches(chars, i, "'''") {
                let delimiter = matches(chars, i, "\"\"\"") ? "\"\"\"" : "'''"
                var j = i + 3
                while j < n, !matches(chars, j, delimiter) { j += 1 }
                j = min(n, j + 3)
                out.append((.string, NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            if quotes.contains(c) || c == multiQuote {
                let end = endOfString(chars, i, quote: c, multiline: c == multiQuote)
                out.append((.string, NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            if lang.dollarVariables, c == 36, i + 1 < n, isIdentStart(chars[i + 1]) || chars[i + 1] == 123 {
                var j = i + 1
                if chars[j] == 123 { while j < n, chars[j] != 125, chars[j] != 10 { j += 1 }; j += 1 }
                else { while j < n, isIdent(chars[j]) { j += 1 } }
                out.append((.variable, NSRange(location: i, length: min(j, n) - i)))
                i = min(j, n)
                continue
            }
            if isDigit(c), i == 0 || !isIdent(chars[i - 1]) {
                var j = i + 1
                while j < n, isIdent(chars[j]) || chars[j] == 46 { j += 1 }
                out.append((.number, NSRange(location: i, length: j - i)))
                i = j
                continue
            }
            if isIdentStart(c) || (c == 64 && i + 1 < n && isIdentStart(chars[i + 1])) {   // @attribute
                var j = i + 1
                while j < n, isIdent(chars[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                let key = lang.caseInsensitive ? word.lowercased() : word
                var k = j
                while k < n, chars[k] == 32 { k += 1 }
                let token: Token? =
                    lang.control.contains(key) ? .control
                    : lang.keywords.contains(key) || lang.constants.contains(key) || c == 64 ? .keyword
                    : k < n && chars[k] == 40 ? .function
                    : lang.capitalizedAreTypes && c >= 65 && c <= 90 ? .type
                    : nil
                if let token { out.append((token, NSRange(location: i, length: j - i))) }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    private static func jsonTokens(_ chars: [UInt16]) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == 34 {
                let end = endOfString(chars, i, quote: 34, multiline: false)
                var k = end
                while k < n, chars[k] == 32 || chars[k] == 9 { k += 1 }
                out.append((k < n && chars[k] == 58 ? .property : .string, NSRange(location: i, length: end - i)))
                i = end
            } else if isDigit(c) || (c == 45 && i + 1 < n && isDigit(chars[i + 1])) {
                var j = i + 1
                while j < n, isIdent(chars[j]) || chars[j] == 46 || chars[j] == 43 || chars[j] == 45 { j += 1 }
                out.append((.number, NSRange(location: i, length: j - i)))
                i = j
            } else if matches(chars, i, "true") || matches(chars, i, "false") || matches(chars, i, "null") {
                let length = matches(chars, i, "false") ? 5 : 4
                out.append((.keyword, NSRange(location: i, length: length)))
                i += length
            } else if matches(chars, i, "//") {
                let end = endOfLine(chars, i)
                out.append((.comment, NSRange(location: i, length: end - i)))
                i = end
            } else {
                i += 1
            }
        }
        return out
    }

    /// YAML, TOML, INI and .env: `key:` / `key =`, [sections], comments, strings and scalars.
    private static func keyValueTokens(_ chars: [UInt16], _ lang: Language) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        var lineStart = 0
        let n = chars.count
        while lineStart < n {
            let lineEnd = endOfLine(chars, lineStart)
            var i = lineStart
            while i < lineEnd, chars[i] == 32 || chars[i] == 9 { i += 1 }
            if i < lineEnd, lang.lineComments.contains(where: { matches(chars, i, $0) }) {
                out.append((.comment, NSRange(location: i, length: lineEnd - i)))
            } else if i < lineEnd, chars[i] == 91, lang.kind == .ini {
                out.append((.type, NSRange(location: i, length: lineEnd - i)))
            } else {
                if i < lineEnd, chars[i] == 45, i + 1 < lineEnd, chars[i + 1] == 32 { i += 2 }   // "- " list item
                // key up to ':' (YAML) or '=' (INI/TOML)
                var j = i
                let separator: UInt16 = lang.kind == .yaml ? 58 : 61
                while j < lineEnd, chars[j] != separator, chars[j] != 34, chars[j] != 39, chars[j] != 35 { j += 1 }
                if j < lineEnd, chars[j] == separator, j > i {
                    out.append((.property, NSRange(location: i, length: j - i)))
                    i = j + 1
                }
                // value
                while i < lineEnd, chars[i] == 32 { i += 1 }
                if i < lineEnd {
                    let c = chars[i]
                    if c == 34 || c == 39 {
                        let end = min(endOfString(chars, i, quote: c, multiline: false), lineEnd)
                        out.append((.string, NSRange(location: i, length: end - i)))
                    } else {
                        var valueEnd = lineEnd
                        if let hash = (i..<lineEnd).first(where: { chars[$0] == 35 && $0 > i && chars[$0 - 1] == 32 }) {
                            out.append((.comment, NSRange(location: hash, length: lineEnd - hash)))
                            valueEnd = hash
                        }
                        let value = String(utf16CodeUnits: Array(chars[i..<valueEnd]), count: valueEnd - i)
                            .trimmingCharacters(in: .whitespaces)
                        let range = NSRange(location: i, length: value.utf16.count)
                        if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(value.lowercased()) {
                            out.append((.keyword, range))
                        } else if Double(value) != nil {
                            out.append((.number, range))
                        } else if !value.isEmpty, lang.kind == .yaml, !["|", ">", "|-", ">-"].contains(value) {
                            out.append((.string, range))
                        }
                    }
                }
            }
            lineStart = lineEnd + 1
        }
        return out
    }

    private static func markdownTokens(_ source: String) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        let ns = source as NSString
        func add(_ pattern: String, _ token: Token, options: NSRegularExpression.Options = [.anchorsMatchLines], group: Int = 0) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                out.append((token, match.range(at: group)))
            }
        }
        add(#"^#{1,6} .*$"#, .heading)
        add(#"^\s*([-*+]|\d+\.) "#, .keyword)
        add(#"^>.*$"#, .comment)
        add(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, .emphasis)
        add(#"\[[^\]\n]+\]"#, .keyword)
        add(#"\]\(([^)\s]+)\)"#, .string, group: 1)
        add(#"`[^`\n]+`"#, .string)
        add(#"^```[\s\S]*?^```"#, .string, options: [.anchorsMatchLines])
        return out
    }

    private static func markupTokens(_ chars: [UInt16]) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        var i = 0
        let n = chars.count
        while i < n {
            if matches(chars, i, "<!--") {
                var j = i + 4
                while j < n, !matches(chars, j, "-->") { j += 1 }
                j = min(n, j + 3)
                out.append((.comment, NSRange(location: i, length: j - i)))
                i = j
            } else if chars[i] == 60 {   // <
                var j = i + 1
                if j < n, chars[j] == 47 || chars[j] == 63 || chars[j] == 33 { j += 1 }   // </ <? <!
                let nameStart = j
                while j < n, isIdent(chars[j]) || chars[j] == 45 || chars[j] == 58 || chars[j] == 46 { j += 1 }
                if j > nameStart { out.append((.tag, NSRange(location: nameStart, length: j - nameStart))) }
                while j < n, chars[j] != 62 {   // attributes until >
                    if chars[j] == 34 || chars[j] == 39 {
                        let end = endOfString(chars, j, quote: chars[j], multiline: true)
                        out.append((.string, NSRange(location: j, length: end - j)))
                        j = end
                    } else if isIdentStart(chars[j]) {
                        let start = j
                        while j < n, isIdent(chars[j]) || chars[j] == 45 || chars[j] == 58 { j += 1 }
                        out.append((.property, NSRange(location: start, length: j - start)))
                    } else {
                        j += 1
                    }
                }
                i = min(n, j + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    private static func cssTokens(_ chars: [UInt16]) -> [(Token, NSRange)] {
        var out: [(Token, NSRange)] = []
        var i = 0
        let n = chars.count
        var inBlock = 0
        while i < n {
            let c = chars[i]
            if matches(chars, i, "/*") {
                var j = i + 2
                while j < n, !matches(chars, j, "*/") { j += 1 }
                j = min(n, j + 2)
                out.append((.comment, NSRange(location: i, length: j - i)))
                i = j
            } else if c == 34 || c == 39 {
                let end = endOfString(chars, i, quote: c, multiline: false)
                out.append((.string, NSRange(location: i, length: end - i)))
                i = end
            } else if c == 123 { inBlock += 1; i += 1 }
            else if c == 125 { inBlock = max(0, inBlock - 1); i += 1 }
            else if inBlock > 0, isIdentStart(c) || c == 45 {
                var j = i
                while j < n, isIdent(chars[j]) || chars[j] == 45 { j += 1 }
                var k = j
                while k < n, chars[k] == 32 { k += 1 }
                if k < n, chars[k] == 58 { out.append((.property, NSRange(location: i, length: j - i))) }
                i = j
            } else if isDigit(c) {
                var j = i
                while j < n, isIdent(chars[j]) || chars[j] == 46 || chars[j] == 37 { j += 1 }
                out.append((.number, NSRange(location: i, length: j - i)))
                i = j
            } else if inBlock == 0, isIdentStart(c) || c == 46 || c == 35 {
                var j = i + 1
                while j < n, isIdent(chars[j]) || chars[j] == 45 { j += 1 }
                out.append((c == 46 || c == 35 ? .type : .tag, NSRange(location: i, length: j - i)))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}
