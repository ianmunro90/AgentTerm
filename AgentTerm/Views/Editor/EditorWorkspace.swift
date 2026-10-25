import Combine
import Foundation
import UIKit

/// One window's read-only editor for a session: the file tree and git state (ExplorerModel),
/// open tabs, and the hooks that hand things to Claude Code in the terminal.
@MainActor
final class EditorWorkspace: ObservableObject {
    enum Activity: String, CaseIterable {
        case explorer, search, sourceControl
    }

    /// A place in a file to scroll to and flash (a search match).
    struct Reveal: Equatable {
        let path: String
        /// 1-based.
        let line: Int
        /// UTF-16 column and length within the line.
        let column: Int
        let length: Int
        let id = UUID()
    }

    struct Tab: Identifiable, Equatable {
        enum Kind: Equatable {
            case file
            case diff(ExplorerModel.Change, ExplorerModel.DiffScope)
            case commit(ExplorerModel.Commit)
            /// One file of a commit, compared with the commit's first parent.
            case commitFile(ExplorerModel.Commit, ExplorerModel.CommitFile)
        }

        let kind: Kind
        let path: String
        /// A preview tab (italic) is replaced by the next thing opened, as in VS Code.
        var isPreview: Bool

        var id: String {
            switch kind {
            case .file: "file:" + path
            case .diff(_, let scope): "diff:\(scope):" + path
            case .commit(let commit): "commit:" + commit.sha
            case .commitFile(let commit, _): "commitfile:\(commit.sha):" + path
            }
        }

        var title: String {
            switch kind {
            case .file: (path as NSString).lastPathComponent
            case .diff(_, let scope): (path as NSString).lastPathComponent + (scope == .staged ? " (Staged)" : " (Changes)")
            case .commit(let commit): commit.shortSHA + " " + commit.subject
            case .commitFile(let commit, _): (path as NSString).lastPathComponent + " (\(commit.shortSHA))"
            }
        }

        /// A Markdown file, shown rendered unless the source is asked for.
        var isMarkdown: Bool {
            guard case .file = kind else { return false }
            return ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased())
        }

        /// Shows two versions of a file (side by side, or inline).
        var isComparison: Bool {
            switch kind {
            case .diff, .commitFile: true
            case .file, .commit: false
            }
        }
    }

    let explorer: ExplorerModel
    let search: SearchModel
    let session: TerminalSession
    @Published var activity = Activity.explorer
    @Published private(set) var tabs: [Tab] = []
    @Published var selectedTabID: Tab.ID?
    /// Comparisons show as one unified diff instead of side by side (for narrow windows).
    @Published var inlineDiffs = Device.isPhone
    /// Markdown files show their source rather than rendered.
    @Published var markdownSource = false
    /// The Source Control commit box.
    @Published var commitMessage = ""
    /// The search match the open file should scroll to.
    @Published private(set) var reveal: Reveal?
    /// Go to File (⌘P) is showing.
    @Published var showingQuickOpen = false
    /// Bumped to show the find bar in the open tab (⌘F).
    @Published private(set) var findRequest = 0
    /// Commits expanded in the graph to list their files, and the files of those loaded.
    @Published private(set) var expandedCommits: Set<String> = []
    @Published private(set) var commitFiles: [String: [ExplorerModel.CommitFile]] = [:]
    /// Problems the language servers found, by path: open files, and every file of a project
    /// whose server checks it all (C#).
    @Published private(set) var diagnostics: [String: [LanguageServer.Diagnostic]] = [:]
    /// Folders with a file with errors below them (for the Explorer).
    @Published private(set) var errorFolders: Set<String> = []
    /// Pushed for files opened in this folder (the freshest), and pulled for whole projects.
    private var fileProblems: [String: [LanguageServer.Diagnostic]] = [:]
    private var projectProblems: [String: [LanguageServer.Diagnostic]] = [:]
    private var projectCheck: Task<Void, Never>?
    private var projectCheckAgain = false
    /// Per project server (kind and folder): host time of the last check, or nil if the folder
    /// isn't such a project.
    private var projectChecked: [String: Int?] = [:]
    private var revisionWatch: AnyCancellable?
    /// Files opened since the folder was (most recent last): their servers keep checking them
    /// after their tabs close, so the Explorer keeps showing their problems, as VS Code does
    /// for a project. With each one's last-seen modification stamp.
    private var checkedFiles: [String] = []
    private var checkedStamps: [String: String] = [:]
    private static let checkedLimit = 100
    /// Called after a Claude hook pastes into the terminal: the window switches back to it.
    var onHandToClaude: (() -> Void)?
    /// Shows the side bar (for results that land in it, like Find All References).
    var onShowSidebar: (() -> Void)?
    /// A tab opened or was chosen (iPhone shows the editor rather than the side bar then).
    var onShowTab: (() -> Void)?
    private var hasOpened = false
    /// A hand-off to Claude Code is under way (one at a time).
    private var handingOff = false
    private var watcher: Task<Void, Never>?
    /// Language servers on the host, by language and folder, started on first use.
    private var languageServers: [String: LanguageServer] = [:]
    /// Servers that failed to start: not tried again for checking files until then.
    private var serverRetry: [String: Date] = [:]

    init(session: TerminalSession) {
        self.session = session
        explorer = ExplorerModel(session: session)
        search = SearchModel(explorer: explorer)
        // After every refresh (a new folder, changes on the host, git operations).
        revisionWatch = explorer.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor in
                self?.checkProjectProblems()
                await self?.recheckFiles()
            }
        }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    /// While the editor is on screen: check the host every 10 s and refresh when something
    /// changed (files Claude Code edits, commits it makes), so the tree, Source Control and
    /// open tabs keep up. Tabs keep their scroll position.
    func setWatching(_ watching: Bool) {
        watcher?.cancel()
        watcher = nil
        guard watching else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                let open = tabs.compactMap { tab -> String? in if case .file = tab.kind { tab.path } else { nil } }
                let files = open + checkedFiles.filter { !open.contains($0) }
                if await explorer.hasChanged(openFiles: files) {
                    await explorer.refresh()
                }
            }
        }
    }

    /// First time: follow the pane's folder. Later: refresh git state and the tree.
    func didEnterEditor() async {
        if hasOpened {
            await explorer.refresh()
        } else {
            hasOpened = true
            await explorer.followPane(waitForPane: true)
        }
    }

    // MARK: Tabs

    /// Opens `kind`, as a preview unless `pinned`. Opening something already open selects it,
    /// and opening it twice pins it.
    func open(_ kind: Tab.Kind, path: String, pinned: Bool = false) {
        defer { onShowTab?() }
        let tab = Tab(kind: kind, path: path, isPreview: !pinned)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            if selectedTabID == tab.id || pinned { tabs[index].isPreview = false }
            selectedTabID = tab.id
            return
        }
        if !pinned, let preview = tabs.firstIndex(where: \.isPreview) {
            tabs[preview] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
    }

    func pin(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs[index].isPreview = false
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    private func isOpenAsFile(_ path: String) -> Bool {
        tabs.contains { $0.kind == .file && $0.path == path }
    }

    func toggleCommit(_ commit: ExplorerModel.Commit) {
        guard expandedCommits.remove(commit.sha) == nil else { return }
        expandedCommits.insert(commit.sha)
        guard commitFiles[commit.sha] == nil else { return }
        Task {
            commitFiles[commit.sha] = (try? await explorer.files(in: commit)) ?? []
        }
    }

    func openFile(in commit: ExplorerModel.Commit, _ file: ExplorerModel.CommitFile) {
        open(.commitFile(commit, file), path: (explorer.root ?? "") + "/" + file.path)
    }

    /// Opens `path` scrolled to a line, with the match flashed. Markdown shows its source.
    func reveal(_ path: String, line: Int, column: Int, length: Int) {
        if ["md", "markdown", "mdx"].contains((path as NSString).pathExtension.lowercased()) {
            markdownSource = true
        }
        open(.file, path: path)
        reveal = Reveal(path: path, line: line, column: column, length: length)
    }

    /// The language server for `path`'s language in this folder (TypeScript/JavaScript,
    /// Python, shell, YAML, JSON, CSS, HTML, Dockerfile), if there is one for it.
    func languageServer(for path: String) -> LanguageServer? {
        guard let kind = LanguageServer.Kind(path: path), let root = explorer.root else { return nil }
        return languageServer(kind, root: root)
    }

    private func languageServer(_ kind: LanguageServer.Kind, root: String) -> LanguageServer {
        let key = kind.rawValue + ":" + root
        if let server = languageServers[key] { return server }
        let server = LanguageServer(kind: kind, host: session.host, root: root) { [weak self] path, items in
            Task { @MainActor in self?.setDiagnostics(items, for: path) }
        }
        languageServers[key] = server
        return server
    }

    private func serverKey(for path: String) -> String? {
        guard let kind = LanguageServer.Kind(path: path), let root = explorer.root else { return nil }
        return kind.rawValue + ":" + root
    }

    private func existingServer(for path: String) -> LanguageServer? {
        serverKey(for: path).flatMap { languageServers[$0] }
    }

    /// Forgets a server that failed (not one that was merely slow to answer), so the next
    /// lookup starts a fresh one.
    func discardLanguageServer(for path: String) {
        guard let key = serverKey(for: path), let server = languageServers[key] else { return }
        Task {
            guard await server.hasFailed, languageServers[key] === server else { return }
            languageServers[key] = nil
            await server.stop()
        }
    }

    /// Has the file's language server check it (a file tab, as fetched, and later the same
    /// file after its tab closes): VS Code's squiggles and Problems. Quietly does nothing
    /// where there's no server for it.
    func checkProblems(in path: String, text: String) {
        guard let key = serverKey(for: path) else { return }
        remember(path)
        if languageServers[key] == nil, let retry = serverRetry[key], retry > .now { return }
        guard let server = languageServer(for: path) else { return }
        Task {
            do {
                try await server.sync(path: path, text: text)
            } catch {
                // Not installed here, or the connection dropped: try a new one in a while.
                serverRetry[key] = .now + 120
                if await server.hasFailed, languageServers[key] === server {
                    languageServers[key] = nil
                    await server.stop()
                }
            }
        }
    }

    private func setDiagnostics(_ items: [LanguageServer.Diagnostic], for path: String) {
        fileProblems[path] = checkedFiles.contains(path) && !items.isEmpty ? items : nil
        mergeProblems()
    }

    private func remember(_ path: String) {
        checkedFiles.removeAll { $0 == path }
        checkedFiles.append(path)
        while checkedFiles.count > Self.checkedLimit, let oldest = checkedFiles.first(where: { !isOpenAsFile($0) }) {
            forget(oldest)
        }
    }

    /// Stops checking a file (gone from the host, or long unopened): its problems go.
    private func forget(_ path: String) {
        checkedFiles.removeAll { $0 == path }
        checkedStamps[path] = nil
        fileProblems[path] = nil
        mergeProblems()
        if let server = existingServer(for: path) {
            Task { await server.close(path: path) }
        }
    }

    /// After a refresh: files opened earlier but not in a tab now (tabs re-check themselves)
    /// are read again if they changed on the host, so their problems stay current. Ones that
    /// are gone, or outside the folder now shown, are forgotten.
    private func recheckFiles() async {
        guard let root = explorer.root else { return }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        for path in checkedFiles where !path.hasPrefix(prefix) { forget(path) }
        let closed = checkedFiles.filter { !isOpenAsFile($0) }
        guard !closed.isEmpty, let output = try? await explorer.fs.run(#"""
            st() { stat -c '%Y %s %n' -- "$1" 2>/dev/null || stat -f '%m %z %N' -- "$1" 2>/dev/null; }
            printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && st "$f"; done
            """#, ["FILES": closed.joined(separator: "\n")]) else { return }
        var stamps: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            if parts.count == 3 { stamps[String(parts[2])] = parts[0] + " " + parts[1] }
        }
        for path in closed where checkedFiles.contains(path) && !isOpenAsFile(path) {
            guard let stamp = stamps[path] else {
                forget(path)
                continue
            }
            guard checkedStamps[path] != stamp else { continue }
            checkedStamps[path] = stamp
            if case .text(let text)? = try? await explorer.fs.read(path) {
                checkProblems(in: path, text: text)
            }
        }
    }

    /// Open files' problems over the project's, sorted, and which folders hold errors.
    private func mergeProblems() {
        let merged = projectProblems.merging(fileProblems) { _, open in open }
            .mapValues { $0.sorted { ($0.line, $0.character) < ($1.line, $1.character) } }
        if merged != diagnostics { diagnostics = merged }
        var folders: Set<String> = []
        for (path, problems) in merged where problems.contains(where: { $0.severity == .error }) {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1, folders.insert(folder).inserted {
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        if folders != errorFolders { errorFolders = folders }
    }

    /// Whole-project problems (C# solutions): when the folder is such a project, its server
    /// checks every file, and again after each refresh, told which files changed on the host
    /// since (it doesn't watch them itself). Runs one at a time.
    func checkProjectProblems() {
        guard projectCheck == nil else {
            projectCheckAgain = true
            return
        }
        guard let root = explorer.root else { return }
        projectCheck = Task {
            for kind in LanguageServer.Kind.projectWide {
                await checkProject(kind, root: root)
            }
            // Problems from a folder no longer shown go.
            let prefix = root.hasSuffix("/") ? root : root + "/"
            projectProblems = projectProblems.filter { $0.key.hasPrefix(prefix) }
            mergeProblems()
            projectCheck = nil
            if projectCheckAgain {
                projectCheckAgain = false
                checkProjectProblems()
            }
        }
    }

    private func checkProject(_ kind: LanguageServer.Kind, root: String) async {
        let key = kind.rawValue + ":" + root
        if case .some(.none) = projectChecked[key] { return }   // not a project
        if languageServers[key] == nil, let retry = serverRetry[key], retry > .now { return }
        let since = projectChecked[key] ?? nil
        let names = (since == nil ? kind.projectMarkers : kind.projectFiles).map { "-name '\($0)'" }.joined(separator: " -o ")
        // Host time first, then the project's files changed since the last look; the first
        // time, whether there's a project file at all.
        // "Changed since" is a stamp file on the host (find -newer works with GNU and BSD find):
        // touched before each look, moved into place after it.
        let stamp = #"M="${TMPDIR:-/tmp}/agentterm-stamp-$(id -u)-$(printf %s "$P" | cksum | cut -d ' ' -f 1)"; "#
        let script = since == nil
            ? #"cd "$P" || exit; date +%s; "# + stamp + #"touch "$M"; find . -maxdepth 4 \( -name .git -o -name node_modules -o -name bin -o -name obj \) -prune -o \( "# + names + #" \) -print -quit"#
            : #"cd "$P" || exit; date +%s; "# + stamp + #"touch "$M.next"; [ -e "$M" ] || touch -t 197001010000 "$M"; "#
                + #"find . \( -name .git -o -name node_modules -o -name bin -o -name obj \) -prune -o \( "# + names + #" \) -newer "$M" -print | head -500; mv -f "$M.next" "$M""#
        guard let output = try? await explorer.fs.run(script, ["P": root]) else { return }
        var lines = output.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, let now = Int(lines.removeFirst()) else { return }
        if since == nil, lines.isEmpty {
            projectChecked[key] = .some(nil)
            return
        }
        let changed = lines.map { root + "/" + $0.dropFirst(2) }
        if since != nil, changed.isEmpty {
            projectChecked[key] = now
            return
        }
        let server = languageServer(kind, root: root)
        do {
            if since != nil { await server.filesChanged(changed) }
            guard let found = try await server.projectDiagnostics() else {
                projectChecked[key] = .some(nil)
                return
            }
            projectChecked[key] = now
            projectProblems = projectProblems.filter { LanguageServer.Kind(path: $0.key) != kind }.merging(found) { $1 }
        } catch {
            serverRetry[key] = .now + 120
            if await server.hasFailed, languageServers[key] === server {
                languageServers[key] = nil
                projectChecked[key] = nil
                await server.stop()
            }
        }
    }

    /// Find All References: the language server's, when it can answer; else a search.
    func findReferences(_ query: Symbols.Query) {
        guard let text = query.text, let server = languageServer(for: query.path) else {
            return findReferences(query.word, from: query.path)
        }
        search.prepareReferences(to: query.word)
        activity = .search
        onShowSidebar?()
        Task {
            do {
                let locations = try await server.references(path: query.path, text: text, line: query.hit.line, character: query.hit.character)
                await search.showReferences(to: query.word, at: locations, via: server.kind.displayName)
            } catch {
                discardLanguageServer(for: query.path)
                findReferences(query.word, from: query.path)
            }
        }
    }

    /// VS Code's Find All References, as a whole-word, case-sensitive search over files of
    /// the same language, in the Search view.
    func findReferences(_ word: String, from path: String) {
        search.regex = false
        search.matchCase = true
        search.wholeWord = true
        search.include = Symbols.family(forPath: path).globs.joined(separator: ", ")
        search.query = word
        search.scheduleSearch(delay: .zero)
        activity = .search
        onShowSidebar?()
    }

    func findInFile() {
        findRequest += 1
    }

    func openFile(_ path: String) {
        open(.file, path: path)
    }

    /// From the explorer: files open as files, changed ones with change marks in the gutter.
    func openFromExplorer(_ path: String) {
        open(.file, path: path)
    }

    // MARK: Git

    func commit(all: Bool = false, amend: Bool = false, push: Bool = false) async {
        if await explorer.commit(message: commitMessage, all: all, amend: amend, push: push) {
            commitMessage = ""
        }
    }

    /// Undoes the last commit (changes stay staged) and puts its message back in the box.
    func undoLastCommit() async {
        if let message = await explorer.undoLastCommit(), commitMessage.isEmpty {
            commitMessage = message
        }
    }

    // MARK: Claude Code hooks

    /// Hands a request to Claude Code: pasted at its prompt (no Return, so the question can be
    /// typed after it), after making sure it's running (TmuxService.prepareClaude: reused, or
    /// started in an idle shell or a new window in the editor's folder, waiting for its prompt
    /// and for the user to answer its folder-trust question). `text` is given a function for
    /// paths as Claude Code's folder sees them. Outside tmux, pastes at the prompt as before.
    private func handToClaude(_ text: @escaping (_ display: (String) -> String) -> String) {
        guard !handingOff else { return }
        handingOff = true
        let session = self.session
        let folder = explorer.root ?? explorer.paneDirectory ?? ""
        Task {
            defer { handingOff = false }
            let target = folder.isEmpty ? nil : try? await TmuxService.prepareClaude(on: session.host, tag: session.tag, folder: folder)
            onHandToClaude?()
            guard let target else {
                return session.paste(text(explorer.displayPath))
            }
            let request = text { Self.path($0, from: target.folder) }
            if target.started {
                session.setHandoff("Starting Claude Code…")
                let readiness = (try? await TmuxService.waitForClaude(on: session.host, pane: target.pane)) ?? .gone
                guard readiness == .ready else {
                    UIPasteboard.general.string = request
                    session.setHandoff(readiness == .missing ? "Claude Code didn't start: request copied to the clipboard"
                                                             : "Claude Code isn't ready: request copied to the clipboard", for: 5)
                    return
                }
                session.setHandoff(nil)
            }
            // A moment for tmux to show the pane (and its paste mode) to this window.
            try? await Task.sleep(for: .milliseconds(target.started ? 500 : 250))
            session.paste(request)
        }
    }

    /// `path` relative to `folder` if it's inside it, else in full.
    private static func path(_ path: String, from folder: String) -> String {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path
    }

    func askAboutFile(_ path: String) {
        handToClaude { $0(path) + " " }
    }

    func askAboutSelection(in path: String, lines: ClosedRange<Int>) {
        let range = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        handToClaude { "\($0(path)) (\(range)) " }
    }

    func askAboutSymbol(_ word: String, in path: String, line: Int?) {
        handToClaude { "`\(word)` (\($0(path))\(line.map { ":\($0)" } ?? "")) " }
    }

    /// Hands problems the language server found to Claude, to fix.
    func askToFix(_ problems: [LanguageServer.Diagnostic], in path: String) {
        guard !problems.isEmpty else { return }
        if problems.count == 1, let problem = problems.first {
            return handToClaude { "Fix this problem in \($0(path)) (line \(problem.line + 1)): \(problem.message) " }
        }
        let list = problems.prefix(30).map { "- line \($0.line + 1): \($0.message.components(separatedBy: "\n")[0])" }
        handToClaude { "Fix these problems in \($0(path)):\n" + list.joined(separator: "\n") + "\n" }
    }

    func reviewChange(_ change: ExplorerModel.Change, scope: ExplorerModel.DiffScope) {
        let what = switch scope {
        case .head: change.letter == "U" ? "the new file" : "the uncommitted changes to"
        case .staged: "the staged changes to"
        case .unstaged: "the unstaged changes to"
        }
        handToClaude { "Review \(what) \($0(change.path)) " }
    }

    func askClaudeToCommit() {
        handToClaude { _ in "Write a commit message for the staged changes and commit them. " }
    }

    func reviewAllChanges() {
        handToClaude { _ in "Review the uncommitted changes in this repo (git diff HEAD, plus untracked files): look for bugs, risky edits and anything I should check before committing. " }
    }

    func reviewCommit(_ commit: ExplorerModel.Commit) {
        handToClaude { _ in "Review commit \(commit.shortSHA) (\"\(commit.subject)\") " }
    }

    func close() {
        setWatching(false)
        explorer.close()
        for server in languageServers.values { Task { await server.stop() } }
        languageServers = [:]
        projectCheck?.cancel()
        fileProblems = [:]
        checkedFiles = []
        checkedStamps = [:]
        projectProblems = [:]
        mergeProblems()
    }
}
