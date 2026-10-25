import Citadel
import Foundation
import NIOCore

/// A language server on the host (typescript-language-server, pyright-langserver, csharp-ls,
/// bash, YAML, JSON, CSS, HTML, Dockerfile), spoken to over its stdin/stdout: an SSH shell channel without
/// a terminal (so bytes pass untouched) that `exec`s the server. JSON-RPC framed with
/// Content-Length headers, as LSP specifies. Problems it finds in open files arrive through
/// `onDiagnostics`.
actor LanguageServer {
    enum Kind: String {
        case typescript, python, csharp, shell, yaml, json, css, html, dockerfile

        /// Servers that check a whole project, not just open files (C#: the solution), so the
        /// Explorer can mark every file with problems; with the files that make one a project.
        static let projectWide: [Kind] = [.csharp]
        var projectMarkers: [String] { self == .csharp ? ["*.sln", "*.slnx", "*.csproj"] : [] }
        /// Files whose changes on disk the server needs to hear about (it doesn't watch them).
        var projectFiles: [String] { self == .csharp ? ["*.cs", "*.csproj", "*.sln", "*.slnx", "*.props", "*.targets"] : [] }

        init?(path: String) {
            let name = (path as NSString).lastPathComponent.lowercased()
            switch (name as NSString).pathExtension {
            case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs": self = .typescript
            case "py", "pyi": self = .python
            case "cs", "csx": self = .csharp
            case "sh", "bash", "ksh", "command": self = .shell
            case "yml", "yaml": self = .yaml
            case "json", "jsonc", "webmanifest", "code-workspace": self = .json
            case "css", "scss", "less": self = .css
            case "html", "htm", "xhtml": self = .html
            case "dockerfile", "containerfile": self = .dockerfile
            default:
                if [".bashrc", ".bash_profile", ".bash_aliases", ".bash_login", ".bash_logout", ".profile"].contains(name) {
                    self = .shell
                } else if [".babelrc", ".eslintrc", ".jshintrc", ".swcrc"].contains(name) {
                    self = .json
                } else if name == "dockerfile" || name == "containerfile" || name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") {
                    self = .dockerfile
                } else {
                    return nil
                }
            }
        }

        var command: String {
            switch self {
            case .typescript: "typescript-language-server --stdio"
            case .python: "pyright-langserver --stdio"
            case .csharp: "csharp-ls"
            case .shell: "bash-language-server start"
            case .yaml: "yaml-language-server --stdio"
            case .json: "vscode-json-language-server --stdio"
            case .css: "vscode-css-language-server --stdio"
            case .html: "vscode-html-language-server --stdio"
            case .dockerfile: "docker-langserver --stdio"
            }
        }

        /// Shown on the docs card.
        var displayName: String {
            switch self {
            case .typescript: "TypeScript"
            case .python: "Pyright"
            case .csharp: "C#"
            case .shell: "Bash"
            case .yaml: "YAML"
            case .json: "JSON"
            case .css: "CSS"
            case .html: "HTML"
            case .dockerfile: "Dockerfile"
            }
        }

        func languageID(_ path: String) -> String {
            let name = (path as NSString).lastPathComponent.lowercased()
            switch (name as NSString).pathExtension {
            case "tsx": return "typescriptreact"
            case "js", "mjs", "cjs": return "javascript"
            case "jsx": return "javascriptreact"
            case "py", "pyi": return "python"
            case "scss": return "scss"
            case "less": return "less"
            default: break
            }
            switch self {
            case .typescript: return "typescript"
            case .python: return "python"
            case .csharp: return "csharp"
            case .shell: return "shellscript"
            case .yaml: return "yaml"
            case .css: return "css"
            case .html: return "html"
            case .dockerfile: return "dockerfile"
            case .json:
                // Files VS Code reads as JSON with comments.
                let jsonc = name.hasSuffix(".jsonc") || name.hasSuffix(".code-workspace") || name.hasPrefix("tsconfig")
                    || name.hasPrefix("jsconfig") || name.hasPrefix(".eslintrc") || name.hasPrefix(".babelrc")
                    || name == "devcontainer.json" || name == ".devcontainer.json" || path.contains("/.vscode/")
                return jsonc ? "jsonc" : "json"
            }
        }

        /// What the vscode-langservers-extracted servers want at startup.
        var initializationOptions: [String: Any]? {
            switch self {
            // JSON fetches its own schemas over http(s) rather than asking the client.
            case .json: ["provideFormatter": false, "handledSchemaProtocols": ["file", "http", "https"]]
            case .css, .html: ["provideFormatter": false]
            default: nil
            }
        }

        /// Settings, as `workspace/configuration` asks for them by section; others get null
        /// (defaults). YAML finds its schemas (Compose, GitHub workflows…) in SchemaStore itself.
        var settings: [String: Any] {
            switch self {
            case .json: ["json": ["validate": ["enable": true], "format": ["enable": false], "schemas": Self.jsonSchemas]]
            case .css: ["css": ["validate": true], "scss": ["validate": true], "less": ["validate": true]]
            // csharp-ls asks for "csharp" and logs an exception for null; empty is its defaults.
            case .csharp: ["csharp": [String: Any]()]
            default: [:]
            }
        }

        /// How long to wait for an answer: csharp-ls loads the solution (MSBuild) first.
        var timeout: Double { self == .csharp ? 90 : 15 }

        /// SchemaStore schemas for well-known JSON files (VS Code ships these associations).
        private static let jsonSchemas: [[String: Any]] = [
            (["package.json"], "package"),
            (["tsconfig.json", "tsconfig.*.json", "tsconfig-*.json"], "tsconfig"),
            (["jsconfig.json", "jsconfig.*.json"], "jsconfig"),
            ([".eslintrc", ".eslintrc.json"], "eslintrc"),
            ([".babelrc", ".babelrc.json", "babel.config.json"], "babelrc"),
            ([".prettierrc", ".prettierrc.json"], "prettierrc"),
            ([".stylelintrc", ".stylelintrc.json"], "stylelintrc"),
            (["composer.json"], "composer"),
            (["renovate.json", ".renovaterc", ".renovaterc.json"], "renovate"),
            (["lerna.json"], "lerna"),
            (["nodemon.json"], "nodemon"),
            (["*.webmanifest", "manifest.webmanifest", "site.webmanifest"], "web-manifest-combined"),
            (["vercel.json"], "vercel"),
            (["turbo.json"], "turbo"),
            (["deno.json", "deno.jsonc"], "deno"),
            (["biome.json", "biome.jsonc"], "biome"),
            (["cspell.json", ".cspell.json"], "cspell"),
            ([".markdownlint.json", ".markdownlintrc"], "markdownlint"),
            (["appsettings.json", "appsettings.*.json"], "appsettings"),
            (["global.json"], "global"),
            (["nest-cli.json"], "nest-cli"),
            ([".swcrc"], "swcrc"),
            (["devcontainer.json", ".devcontainer.json"], "devcontainer"),
            (["firebase.json"], "firebase"),
        ].map { files, name in ["fileMatch": files, "url": "https://www.schemastore.org/\(name).json"] }
    }

    /// A problem the server found (LSP's Diagnostic): positions 0-based, UTF-16.
    struct Diagnostic: Sendable, Equatable {
        enum Severity: Int, Sendable, Comparable {
            case error = 1, warning, information, hint
            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }

        let line: Int
        let character: Int
        let endLine: Int
        let endCharacter: Int
        let severity: Severity
        let message: String
        /// "typescript", "shellcheck"… and the rule ("2345", "SC2086").
        let source: String?
        let code: String?
        /// Unused code: VS Code fades it rather than underlining it.
        let unnecessary: Bool

        /// "shellcheck(SC2086)", as VS Code's Problems view puts it.
        var origin: String? {
            switch (source, code) {
            case let (source?, code?): "\(source)(\(code))"
            case let (source?, nil): source
            case let (nil, code?): code
            default: nil
            }
        }

        /// Whether it covers any of `line`, columns `start` to `end`.
        func overlaps(line: Int, from start: Int, to end: Int) -> Bool {
            guard line >= self.line, line <= endLine else { return false }
            let from = line == self.line ? character : 0
            let to = line == endLine ? endCharacter : Int.max
            return start <= max(to, from + 1) && end >= from
        }
    }

    struct Location: Sendable {
        let path: String
        /// 0-based, UTF-16 (LSP's default encoding, as NSString counts).
        let line: Int
        let character: Int
        let length: Int
    }

    struct Hover: Sendable {
        /// The code part (signature), and the rest (docs, Markdown).
        let signature: String
        let docs: String
        /// The docs are plain preformatted text (a man page), best shown monospaced.
        var preformatted = false
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let kind: Kind
    let host: HostProfile
    let root: String
    /// Called with a file's current problems whenever the server publishes them.
    private let onDiagnostics: @Sendable (String, [Diagnostic]) -> Void
    /// The requests the server says it answers ("hover", "definition", "references").
    private var provides: Set<String> = []
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var runner: Task<Void, Never>?
    private var started: Task<Void, Error>?
    private var buffer = Data()
    private var sawReady = false
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    /// Open documents: URI → (version, text).
    private var documents: [String: (version: Int, text: String)] = [:]
    private var failure: Error?

    private static let readyMarker = Data("AGENTTERM-LSP-READY\n".utf8)

    init(kind: Kind, host: HostProfile, root: String, onDiagnostics: @escaping @Sendable (String, [Diagnostic]) -> Void) {
        self.kind = kind
        self.host = host
        self.root = root
        self.onDiagnostics = onDiagnostics
    }

    /// It couldn't start, or stopped: a new one is needed.
    var hasFailed: Bool { failure != nil }

    // MARK: Lifecycle

    /// Starts the server once (later calls wait for that start); throws if it can't run.
    func start() async throws {
        if let failure { throw failure }
        if started == nil {
            started = Task { try await launch() }
        }
        do {
            try await started!.value
        } catch {
            failure = error
            throw error
        }
    }

    private func launch() async throws {
        let client = try await TrustedSSH.connect(to: host, timeout: 10)
        self.client = client
        // Where the setup guide installs servers (npm into ~/.local, .NET into ~/.dotnet),
        // whatever the login shell's own PATH (macOS doesn't include ~/.local/bin).
        let server = #"PATH="$HOME/.local/bin:$HOME/.dotnet/tools:$PATH"; "#
            + #"if [ -x "$HOME/.dotnet/dotnet" ]; then DOTNET_ROOT="$HOME/.dotnet"; PATH="$HOME/.dotnet:$PATH"; export DOTNET_ROOT; fi; "#
            + "export PATH; exec \(kind.command)"
        let command = "cd \(TmuxService.shellQuote(root)) && printf '%s\\n' AGENTTERM-LSP-READY && exec sh -c \(TmuxService.shellQuote(server))\n"
        runner = Task { [weak self] in
            do {
                // A shell request with no PTY: the login shell (so ~/.local/bin is on PATH)
                // reads the command line, then the server owns stdin and stdout.
                try await client.withTTY { inbound, outbound in
                    await self?.attach(outbound)
                    try await outbound.write(ByteBuffer(string: command))
                    for try await output in inbound {
                        if case .stdout(let bytes) = output { await self?.receive(Data(bytes.readableBytesView)) }
                    }
                }
                await self?.ended(Failure(message: "The \(self?.kind.displayName ?? "language") server stopped."))
            } catch {
                await self?.ended(error)
            }
        }
        // The marker, then the server: if it isn't installed the shell exits first.
        try await withCheckedThrowingContinuation { continuation in
            if sawReady { continuation.resume() } else { readyWaiter = continuation }
        }
        var params: [String: Any] = [
            "processId": NSNull(),
            "rootUri": Self.uri(root),
            "workspaceFolders": [["uri": Self.uri(root), "name": (root as NSString).lastPathComponent]],
            "capabilities": [
                "textDocument": [
                    "hover": ["contentFormat": ["markdown", "plaintext"]],
                    "definition": ["linkSupport": false],
                    "references": [:],
                    "synchronization": ["didSave": false],
                    "publishDiagnostics": ["relatedInformation": false, "tagSupport": ["valueSet": [1, 2]]],
                ],
                "workspace": ["configuration": true, "workspaceFolders": true],
            ],
        ]
        if let options = kind.initializationOptions { params["initializationOptions"] = options }
        let result = try await request("initialize", params, timeout: 30)
        let capabilities = (result as? [String: Any])?["capabilities"] as? [String: Any] ?? [:]
        // true, or an options object.
        for name in ["hover", "definition", "references"] {
            let value = capabilities[name + "Provider"]
            if (value as? Bool) == true || value is [String: Any] { provides.insert(name) }
        }
        if ((capabilities["diagnosticProvider"] as? [String: Any])?["workspaceDiagnostics"] as? Bool) == true {
            provides.insert("workspaceDiagnostics")
        }
        notify("initialized", [:])
        if !kind.settings.isEmpty { notify("workspace/didChangeConfiguration", ["settings": kind.settings]) }
    }

    private func attach(_ outbound: TTYStdinWriter) {
        writer = outbound
    }

    private func ended(_ error: Error) {
        failure = failure ?? error
        readyWaiter?.resume(throwing: error)
        readyWaiter = nil
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending = [:]
    }

    func stop() async {
        if writer != nil, failure == nil {
            _ = try? await request("shutdown", nil, timeout: 3)
            notify("exit", nil)
        }
        failure = Failure(message: "Stopped.")
        runner?.cancel()
        try? await client?.close()
        client = nil
        writer = nil
    }

    // MARK: Requests

    /// What the server says about the symbol at a position: hover text, definitions.
    func hover(path: String, text: String, line: Int, character: Int) async throws -> Hover? {
        try await prepare(path: path, text: text)
        guard provides.contains("hover") else { return nil }
        var result = try await request("textDocument/hover", position(path, line, character))
        // tsserver can answer before the project has loaded (just "import x" or "any"): retry.
        for _ in 0..<4 where kind == .typescript && Self.looksUnresolved(result) {
            try await Task.sleep(for: .milliseconds(700))
            result = try await request("textDocument/hover", position(path, line, character))
        }
        return Self.parseHover(result)
    }

    func definition(path: String, text: String, line: Int, character: Int) async throws -> [Location] {
        try await prepare(path: path, text: text)
        guard provides.contains("definition") else { return [] }
        return Self.parseLocations(try await request("textDocument/definition", position(path, line, character)))
    }

    func references(path: String, text: String, line: Int, character: Int) async throws -> [Location] {
        try await prepare(path: path, text: text)
        guard provides.contains("references") else { throw Failure(message: "\(kind.displayName) doesn't find references.") }
        var params = position(path, line, character)
        params["context"] = ["includeDeclaration": true]
        return Self.parseLocations(try await request("textDocument/references", params, timeout: 30))
    }

    /// Opens the file in the server (or updates it), so it checks it: its problems come back
    /// through `onDiagnostics`.
    func sync(path: String, text: String) async throws {
        try await prepare(path: path, text: text)
    }

    /// Every file's problems, for a server that checks a whole project (LSP's workspace
    /// diagnostics); nil if it doesn't. Files it leaves out have none.
    func projectDiagnostics() async throws -> [String: [Diagnostic]]? {
        try await start()
        guard provides.contains("workspaceDiagnostics") else { return nil }
        let result = try await request("workspace/diagnostic", ["previousResultIds": [Any]()], timeout: 180)
        var problems: [String: [Diagnostic]] = [:]
        for report in (result as? [String: Any])?["items"] as? [[String: Any]] ?? [] {
            guard let uri = report["uri"] as? String, let path = Self.path(fromURI: uri) else { continue }
            let items = Self.parseDiagnostics(report["items"])
            if !items.isEmpty { problems[path] = items }
        }
        return problems
    }

    /// Files changed on the host (by Claude Code, say): the server reloads them.
    func filesChanged(_ paths: [String]) {
        guard failure == nil, !paths.isEmpty else { return }
        notify("workspace/didChangeWatchedFiles", ["changes": paths.map { ["uri": Self.uri($0), "type": 2] }])
    }

    /// The file's tab closed: the server can stop checking it.
    func close(path: String) {
        let uri = Self.uri(path)
        guard documents.removeValue(forKey: uri) != nil, failure == nil else { return }
        notify("textDocument/didClose", ["textDocument": ["uri": uri]])
    }

    /// Starts the server and tells it about the file (open, or changed since).
    private func prepare(path: String, text: String) async throws {
        try await start()
        let uri = Self.uri(path)
        if let open = documents[uri] {
            guard open.text != text else { return }
            documents[uri] = (open.version + 1, text)
            notify("textDocument/didChange", [
                "textDocument": ["uri": uri, "version": open.version + 1],
                "contentChanges": [["text": text]],
            ])
        } else {
            documents[uri] = (1, text)
            notify("textDocument/didOpen", [
                "textDocument": ["uri": uri, "languageId": kind.languageID(path), "version": 1, "text": text],
            ])
            // tsserver loads the file's project after opening it; give it a moment.
            if kind == .typescript { try await Task.sleep(for: .milliseconds(900)) }
        }
    }

    private func position(_ path: String, _ line: Int, _ character: Int) -> [String: Any] {
        ["textDocument": ["uri": Self.uri(path)], "position": ["line": line, "character": character]]
    }

    private func request(_ method: String, _ params: Any?, timeout: Double? = nil) async throws -> Any? {
        if let failure { throw failure }
        let timeout = method == "shutdown" ? (timeout ?? 3) : max(timeout ?? 0, kind.timeout)
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, method)
            }
        }
        let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = reply?["error"] as? [String: Any] {
            throw Failure(message: error["message"] as? String ?? "\(method) failed.")
        }
        return reply?["result"]
    }

    private func expire(_ id: Int, _ method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: Failure(message: "\(kind.displayName) didn't answer \(method) in time."))
    }

    private func notify(_ method: String, _ params: Any?) {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        send(message)
    }

    private func send(_ message: [String: Any]) {
        guard let writer, let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var bytes = ByteBuffer(string: "Content-Length: \(body.count)\r\n\r\n")
        bytes.writeBytes(body)
        Task { try? await writer.write(bytes) }
    }

    // MARK: Incoming

    private func receive(_ data: Data) {
        buffer.append(data)
        if !sawReady {
            // Anything a login script prints comes before the marker; skip it.
            guard let marker = buffer.range(of: Self.readyMarker) else { return }
            buffer.removeSubrange(..<marker.upperBound)
            sawReady = true
            readyWaiter?.resume()
            readyWaiter = nil
        }
        while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
            let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            guard let length = header.split(separator: "\r\n")
                .first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap({ Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }) else {
                buffer.removeSubrange(..<headerEnd.upperBound)
                continue
            }
            let start = headerEnd.upperBound
            guard buffer.distance(from: start, to: buffer.endIndex) >= length else { return }
            let end = buffer.index(start, offsetBy: length)
            let body = Data(buffer[start..<end])
            buffer.removeSubrange(..<end)
            handle(body)
        }
    }

    private func handle(_ body: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let id = message["id"] as? Int
        if let method = message["method"] as? String {
            guard let id else {
                if method == "textDocument/publishDiagnostics", let params = message["params"] as? [String: Any],
                   let uri = params["uri"] as? String, let path = Self.path(fromURI: uri) {
                    onDiagnostics(path, Self.parseDiagnostics(params["diagnostics"]))
                }
                return
            }
            // A request from the server: answer so it doesn't wait (settings: ours, or defaults).
            var result: Any = NSNull()
            if method == "workspace/configuration" {
                let items = (message["params"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                result = items.map { setting($0["section"] as? String) ?? NSNull() }
            } else if method == "workspace/workspaceFolders" {
                result = [["uri": Self.uri(root), "name": (root as NSString).lastPathComponent]]
            }
            send(["jsonrpc": "2.0", "id": id, "result": result])
        } else if let id, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: body)
        }
    }

    /// A section of `kind.settings` by its dotted name ("json", "css.lint").
    private func setting(_ section: String?) -> Any? {
        guard let section, !section.isEmpty else { return nil }
        var node: Any? = kind.settings
        for part in section.split(separator: ".") {
            node = (node as? [String: Any])?[String(part)]
        }
        return node
    }

    // MARK: Parsing

    static func uri(_ path: String) -> String {
        URL(fileURLWithPath: path).absoluteString
    }

    private static func path(fromURI uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    private static func parseLocations(_ result: Any?) -> [Location] {
        let items: [[String: Any]] = (result as? [[String: Any]]) ?? ((result as? [String: Any]).map { [$0] } ?? [])
        return items.compactMap { item in
            // Location (uri, range) or LocationLink (targetUri, targetSelectionRange).
            guard let uri = (item["uri"] ?? item["targetUri"]) as? String, let path = path(fromURI: uri),
                  let range = (item["range"] ?? item["targetSelectionRange"] ?? item["targetRange"]) as? [String: Any],
                  let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int else { return nil }
            let length = (end["line"] as? Int) == line ? max((end["character"] as? Int ?? character) - character, 0) : 0
            return Location(path: path, line: line, character: character, length: length)
        }
    }

    private static func parseDiagnostics(_ value: Any?) -> [Diagnostic] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let range = item["range"] as? [String: Any],
                  let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
                  let line = start["line"] as? Int, let character = start["character"] as? Int,
                  let message = item["message"] as? String else { return nil }
            let code = (item["code"] as? String) ?? (item["code"] as? Int).map(String.init)
            return Diagnostic(line: line, character: character,
                              endLine: end["line"] as? Int ?? line, endCharacter: end["character"] as? Int ?? character,
                              severity: Diagnostic.Severity(rawValue: item["severity"] as? Int ?? 1) ?? .error,
                              message: message.replacingOccurrences(of: "\u{A0}", with: " "),
                              // csharp-ls says "lsp": no help.
                              source: (item["source"] as? String).flatMap { $0 == "lsp" ? nil : $0 }, code: code,
                              unnecessary: (item["tags"] as? [Int] ?? []).contains(1))
        }
    }

    private static func hoverText(_ result: Any?) -> String {
        guard let contents = (result as? [String: Any])?["contents"] else { return "" }
        func text(_ value: Any) -> String {
            if let string = value as? String { return string }
            if let object = value as? [String: Any] {
                if let language = object["language"] as? String, let value = object["value"] as? String {
                    return "```\(language)\n\(value)\n```"
                }
                return object["value"] as? String ?? ""
            }
            return ""
        }
        if let list = contents as? [Any] { return list.map(text).joined(separator: "\n\n") }
        return text(contents)
    }

    private static func looksUnresolved(_ result: Any?) -> Bool {
        let code = parseHover(result)?.signature.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return code == "any" || (code.hasPrefix("import ") && !code.contains("\n"))
    }

    /// Splits hover Markdown into a leading code block (the signature) and the rest (docs).
    private static func parseHover(_ result: Any?) -> Hover? {
        let markdown = hoverText(result).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else { return nil }
        guard markdown.hasPrefix("```"), let lineEnd = markdown.firstIndex(of: "\n"),
              let close = markdown.range(of: "\n```", range: lineEnd..<markdown.endIndex) else {
            return Hover(signature: "", docs: cleanDocs(markdown))
        }
        let language = markdown[markdown.index(markdown.startIndex, offsetBy: 3)..<lineEnd].trimmingCharacters(in: .whitespaces)
        let code = String(markdown[markdown.index(after: lineEnd)..<close.lowerBound]).trimmingCharacters(in: .newlines)
        let rest = cleanDocs(String(markdown[close.upperBound...].drop { $0 == "`" }))
        // bash-language-server puts man pages and comments in plain-text blocks: docs, not code.
        if ["man", "txt", "text", "plaintext"].contains(language) {
            return Hover(signature: "", docs: rest.isEmpty ? code : code + "\n\n" + rest, preformatted: rest.isEmpty)
        }
        return Hover(signature: code, docs: rest)
    }

    /// Hover Markdown for the card's inline-only renderer: no images (CSS's Baseline badges),
    /// headings in bold, fences dropped, TypeScript's tags ("*@param* `a` — …") in bold.
    private static func cleanDocs(_ markdown: String) -> String {
        var docs = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if docs.hasPrefix("---") { docs = String(docs.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        docs = docs.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        docs = docs.components(separatedBy: "\n").compactMap { line -> String? in
            if line.hasPrefix("```") { return nil }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return "**" + line[heading.upperBound...] + "**"
            }
            return line
        }.joined(separator: "\n")
        return docs.replacingOccurrences(of: "*@param*", with: "**Parameter**")
            .replacingOccurrences(of: "*@returns*", with: "**Returns**")
            .replacingOccurrences(of: "*@throws*", with: "**Throws**")
            .replacingOccurrences(of: "*@deprecated*", with: "**Deprecated**")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
