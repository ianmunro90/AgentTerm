#if DEBUG
import UIKit

/// Launch arguments that drive the editor in the simulator, so features can be checked (and
/// screenshotted) without tapping. Debug builds only; the event log records the results.
///
/// - `-openEditor`: switch to the editor a few seconds after launch (RootView).
/// - `-openFirstChange`, `-openChangedFile <path from repo root>`: open a change or a file;
///   `-openFile <path from repo root>[,…]` any files (several in turn, as previews); `-expand <name>` a top-level folder.
/// - `-askClaude <path from repo root>`: Ask Claude About This File (starts Claude Code if needed).
/// - `-showProblems`: open the Problems list; `-problemCard`: the card for the first problem.
/// - `-sourceControl`, `-inline`, `-toggleInline`, `-expandMerge`: Source Control views.
/// - `-search <text> [-revealLast]`, `-quickOpen`: Search and Go to File.
/// - `-lookup <a,b,…> <file>`: log search-based symbol lookups.
/// - `-symbolCard <name> [-references | -goDefinition]`: open the docs card for the last use
///   of a name in the open file (or find its references, or go to its definition).
/// - `-gitSelfTest`: stage, commit, undo, push, branch, stash, pull… on the open repository
///   (use a throwaway one with a local bare remote).
/// - `-biggerText`, `-reviewFirstChange`, `-selfTestViewer` (AgentTermApp).
@MainActor
enum EditorDebug {
    /// After the editor opens: whatever the arguments ask for.
    static func run(workspace: EditorWorkspace, settings: AppSettings) async {
        if CommandLine.arguments.contains("-openFirstChange"), let first = workspace.explorer.changes.first {
            workspace.open(.diff(first, .head), path: first.path)
        }
        if let index = CommandLine.arguments.firstIndex(of: "-openChangedFile"), CommandLine.arguments.indices.contains(index + 1),
           let change = workspace.explorer.changes.first(where: { $0.relativePath == CommandLine.arguments[index + 1] }) {
            workspace.open(.file, path: change.path)
        }
        if let index = CommandLine.arguments.firstIndex(of: "-openFile"), CommandLine.arguments.indices.contains(index + 1),
           let root = workspace.explorer.root {
            // Several (a,b,…): one after another in the preview tab, as clicking through the tree.
            let paths = CommandLine.arguments[index + 1].split(separator: ",").map(String.init)
            for (number, path) in paths.enumerated() {
                if number > 0 { try? await Task.sleep(for: .seconds(6)) }
                workspace.open(.file, path: root + "/" + path, pinned: paths.count == 1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "-expand"), CommandLine.arguments.indices.contains(index + 1),
           let row = workspace.explorer.rows.first(where: { $0.entry.name == CommandLine.arguments[index + 1] }) {
            await workspace.explorer.toggle(row.entry)
        }
        if let index = CommandLine.arguments.firstIndex(of: "-askClaude"), CommandLine.arguments.indices.contains(index + 1),
           let root = workspace.explorer.root {
            try? await Task.sleep(for: .seconds(2))
            workspace.askAboutFile(root + "/" + CommandLine.arguments[index + 1])
        }
        if CommandLine.arguments.contains("-sourceControl") { workspace.activity = .sourceControl }
        if CommandLine.arguments.contains("-inline") { workspace.inlineDiffs = true }
        if let index = CommandLine.arguments.firstIndex(of: "-search"), CommandLine.arguments.indices.contains(index + 1) {
            workspace.activity = .search
            workspace.search.query = CommandLine.arguments[index + 1]
            await workspace.search.search()
            EventLog.record("debug search: \(workspace.search.summary ?? "-") first=\(workspace.search.results.first.map { "\($0.relativePath):\($0.matches[0].line) col \($0.matches[0].column)" } ?? "-")")
            if CommandLine.arguments.contains("-revealLast"), let file = workspace.search.results.last, let match = file.matches.last {
                workspace.reveal(file.path, line: match.line, column: match.column, length: match.length)
            }
        }
        if CommandLine.arguments.contains("-quickOpen") { workspace.showingQuickOpen = true }
        if let index = CommandLine.arguments.firstIndex(of: "-lookup"), CommandLine.arguments.indices.contains(index + 2) {
            let from = (workspace.explorer.root ?? "") + "/" + CommandLine.arguments[index + 2]
            for word in CommandLine.arguments[index + 1].split(separator: ",").map(String.init) {
                let found = await Symbols.definitions(of: word, from: from, explorer: workspace.explorer)
                EventLog.record("debug lookup \(word): \(found.count) found")
                for definition in found.prefix(3) {
                    EventLog.record("debug lookup   \(definition.relativePath):\(definition.line) col \(definition.column) rank \(definition.rank) sig=\(definition.signature.debugDescription) docs=\(definition.docs.debugDescription)")
                }
            }
        }
        if CommandLine.arguments.contains("-gitSelfTest") {
            let explorer = workspace.explorer
            @MainActor func log(_ step: String) {
                EventLog.record("gitselftest \(step): branch=\(explorer.branch ?? "-") ↓\(explorer.behind) ↑\(explorer.ahead) staged=\(explorer.changes.filter(\.isStaged).map(\.name)) unstaged=\(explorer.changes.filter(\.hasUnstaged).map(\.name)) head=\(explorer.commits.first?.subject ?? "-") stash=\(explorer.hasStash) failure=\(explorer.failure ?? "-")")
                explorer.failure = nil
            }
            log("start")
            if let change = explorer.changes.first(where: { $0.name == "MouseAssist.swift" }) {
                await explorer.stage(change)
                log("stage MouseAssist")
                if let staged = explorer.change(for: change.path) { await explorer.unstage(staged) }
                log("unstage MouseAssist")
            }
            workspace.commitMessage = "Self-test commit\n\nWith a body line."
            await workspace.commit()
            log("commit")
            await workspace.undoLastCommit()
            log("undo, message=\(workspace.commitMessage.debugDescription)")
            await workspace.commit()
            log("recommit")
            await explorer.push()
            log("push")
            await explorer.fetch()
            log("fetch")
            await explorer.createBranch("selftest-branch")
            log("new branch")
            await explorer.push()
            log("publish")
            await explorer.switchBranch("main")
            log("switch to main")
            await explorer.stash()
            log("stash")
            await explorer.popStash()
            log("pop")
            await explorer.pull()
            log("pull")
            if let untracked = explorer.changes.first(where: { $0.name == "MD-TEST.md" }) {
                await explorer.discard(untracked)
                log("discard untracked MD-TEST.md")
            }
        }
        if CommandLine.arguments.contains("-biggerText") {
            try? await Task.sleep(for: .seconds(8))
            settings.fontSize += 4
        }
        if CommandLine.arguments.contains("-toggleInline") {
            try? await Task.sleep(for: .seconds(5))
            workspace.inlineDiffs.toggle()
        }
        if CommandLine.arguments.contains("-expandMerge"),
           let merge = workspace.explorer.commits.first(where: { $0.parents.count > 1 }) {
            workspace.toggleCommit(merge)
            try? await Task.sleep(for: .seconds(2))
            if let file = workspace.commitFiles[merge.sha]?.first { workspace.openFile(in: merge, file) }
        }
        if CommandLine.arguments.contains("-reviewFirstChange"), let first = workspace.explorer.changes.first {
            try? await Task.sleep(for: .seconds(2))
            workspace.reviewChange(first, scope: .head)
        }
    }

    /// For `-symbolCard`: a query for the last whole-word use of the name in `text`, and
    /// whether to find references rather than show the card.
    static func symbolQuery(path: String, text: String) -> (Symbols.Query, Bool)? {
        guard let index = CommandLine.arguments.firstIndex(of: "-symbolCard"), CommandLine.arguments.indices.contains(index + 1) else {
            return nil
        }
        let word = CommandLine.arguments[index + 1]
        let pattern = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b")
        var line = 0
        var character = 0
        for (number, content) in text.components(separatedBy: "\n").enumerated() {
            if let match = pattern?.firstMatch(in: content, range: NSRange(location: 0, length: (content as NSString).length)) {
                line = number
                character = match.range.location
            }
        }
        let hit = Symbols.Hit(word: word, rect: CGRect(x: 160, y: 240, width: 90, height: 20), line: line, character: character)
        let query = Symbols.Query(hit: hit, path: path, text: text, goDirectly: CommandLine.arguments.contains("-goDefinition"))
        return (query, CommandLine.arguments.contains("-references"))
    }
}

enum ViewerSelfTest {
    /// Layout: no wrapping and a content width past the longest line. Selection mapping: lines
    /// of a file and of a diff map back to the right source lines.
    static func run() {
        let long = "let value = String(decoding: bytes, as: UTF8.self) // " + String(repeating: "word ", count: 40)
        let source = (1...11).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n" + long
        let styled = CodeStyle.numbered(source, path: "x.swift", theme: TerminalTheme.named(nil))
        let scroll = CodeTextView.CodeScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 800))
        scroll.show(styled, theme: TerminalTheme.named(nil))
        scroll.layoutIfNeeded()
        let view = scroll.textView
        view.layoutIfNeeded()
        var fragments = 0
        view.layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: view.layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            fragments += 1
        }
        let used = view.layoutManager.usedRect(for: view.textContainer).width
        EventLog.record("selftest viewer: lines=12 fragments=\(fragments) scrollContent=\(Int(scroll.contentSize.width)) textViewWidth=\(Int(view.frame.width)) longestLineWidth=\(Int(used)) viewportWidth=\(Int(scroll.bounds.width))")

        let ns = styled.text.string as NSString
        let range = NSRange(location: ns.range(of: "line3").location, length: ns.range(of: "line5").upperBound - ns.range(of: "line3").location)
        let display = CodeTextView.Coordinator.displayLines(ns, range)
        EventLog.record("selftest viewer: selecting line3…line5 → display \(display) → file lines \(display.compactMap { styled.lines[$0]?.line })")

        let diff = """
        diff --git a/src/a.swift b/src/a.swift
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -10,4 +10,5 @@ func x() {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        """
        let styledDiff = CodeStyle.styledDiff(diff, root: "/repo", defaultPath: nil, theme: TerminalTheme.named(nil))
        EventLog.record("selftest viewer: diff lines → \(styledDiff.lines.map { $0.map { "\(($0.path as NSString).lastPathComponent):\($0.line)" } ?? "-" })")
    }
}
#endif
