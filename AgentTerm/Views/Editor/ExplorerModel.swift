import Foundation

/// State for the explorer panel: a lazily loaded tree rooted at the active tmux pane's directory
/// (widened to its git repository), plus git status for the Changes list and badges.
@MainActor
final class ExplorerModel: ObservableObject {
    struct Row: Identifiable {
        let entry: RemoteFS.Entry
        let depth: Int
        var id: String { entry.path }
    }

    struct Change: Identifiable, Hashable {
        let path: String
        let relativePath: String
        /// VS Code's letters: M, A, D, R, U (untracked), C (conflict).
        let letter: Character
        /// git's two status columns: index (staged) and working tree.
        var indexStatus: Character = " "
        var worktreeStatus: Character = " "
        var id: String { path }
        var isStaged: Bool { indexStatus != " " && indexStatus != "?" }
        var hasUnstaged: Bool { worktreeStatus != " " }
        var name: String { (relativePath as NSString).lastPathComponent }
        var folder: String { (relativePath as NSString).deletingLastPathComponent }
    }

    @Published private(set) var root: String?
    @Published private(set) var isRepository = false
    @Published private(set) var rows: [Row] = []
    @Published private(set) var changes: [Change] = []
    @Published private(set) var commits: [Commit] = []
    /// The commit graph's lanes, one row per commit.
    @Published private(set) var graph: [CommitGraph.Row] = []
    /// The checked-out branch (nil when detached), its upstream, and how far apart they are.
    @Published private(set) var branch: String?
    @Published private(set) var upstream: String?
    @Published private(set) var ahead = 0
    @Published private(set) var behind = 0
    @Published private(set) var localBranches: [String] = []
    @Published private(set) var isMerging = false
    @Published private(set) var hasStash = false
    /// The git operation running ("Pushing…"), if any.
    @Published private(set) var busy: String?
    /// git's output when an operation failed, for an alert.
    @Published var failure: String?
    /// Bumped on every refresh, so open tabs reload what they show.
    @Published private(set) var revision = 0
    @Published private(set) var isLoading = false
    @Published var error: String?
    /// The followed pane's own directory, for paths relative to where Claude Code runs.
    @Published private(set) var paneDirectory: String?

    struct Commit: Identifiable, Hashable {
        let sha: String
        let parents: [String]
        let subject: String
        let age: String
        let author: String
        /// Refs pointing here, as `git log --decorate=full --format=%D` lists them:
        /// "HEAD -> refs/heads/main", "refs/remotes/origin/main", "tag: refs/tags/v1".
        var refs: [String] = []
        var id: String { sha }
        var shortSHA: String { String(sha.prefix(7)) }
        var isHead: Bool { refs.contains { $0.hasPrefix("HEAD") } }
    }

    /// A file a commit changed, relative to the repository root.
    struct CommitFile: Identifiable, Hashable {
        let path: String
        /// Where it was before a rename or copy, else `path`.
        let oldPath: String
        /// A, M, D, R, C or T.
        let letter: Character
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
    }

    /// Which side of git a diff shows.
    enum DiffScope { case head, staged, unstaged }

    /// Where a version of a file comes from.
    enum Revision: Hashable {
        case worktree, index
        case commit(String)
    }

    let fs: RemoteFS
    private let session: TerminalSession
    private var children: [String: [RemoteFS.Entry]] = [:]
    private var expanded: Set<String> = []
    private var letters: [String: Character] = [:]
    private var changedFolders: Set<String> = []
    /// The host's state at the last change check (see `hasChanged`).
    private var fingerprint: String?

    init(session: TerminalSession) {
        self.session = session
        fs = RemoteFS(host: session.host)
    }

    // MARK: Root

    /// Opens the folder of the pane this window shows (its repository root if it's in one).
    /// `waitForPane` keeps checking for a few seconds, for a panel opened while the session's
    /// startup command is still attaching tmux.
    func followPane(waitForPane: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var pane = try await TmuxService.currentPath(on: session.host, tag: session.tag)
            for _ in 0..<(waitForPane ? 4 : 0) where pane == nil {
                try? await Task.sleep(for: .seconds(1.5))
                pane = try await TmuxService.currentPath(on: session.host, tag: session.tag)
            }
            var start = pane ?? ""
            if start.isEmpty {
                start = try await fs.run(#"cd && pwd"#).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            paneDirectory = start
            let top = try await fs.run(#"cd "$P" && git rev-parse --show-toplevel 2>/dev/null"#, ["P": start])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await open(top.isEmpty ? start : top, isRepository: !top.isEmpty)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openParent() async {
        guard let root, root != "/" else { return }
        let parent = (root as NSString).deletingLastPathComponent
        let top = (try? await fs.run(#"cd "$P" && git rev-parse --show-toplevel 2>/dev/null"#, ["P": parent]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await open(parent, isRepository: top == parent)
    }

    private func open(_ path: String, isRepository: Bool) async {
        root = path
        self.isRepository = isRepository
        children = [:]
        expanded = []
        error = nil
        await refresh()
    }

    /// Reloads the open folders and git status.
    func refresh() async {
        guard let root else { return }
        isLoading = true
        defer { isLoading = false }
        for path in [root] + expanded.sorted() {
            children[path] = try? await fs.list(path)
        }
        if children[root] == nil {
            error = "Couldn't read \(root)."
        }
        await refreshGitStatus()
        await refreshBranch()
        await refreshCommits()
        rebuildRows()
        revision += 1
    }

    /// Whether anything shown has changed on the host since the last check: git status, HEAD
    /// and refs, the open folders' entries, the open files. One cheap round trip (a hash), so
    /// the editor can poll it while Claude Code works. The first check only takes a baseline.
    func hasChanged(openFiles: [String]) async -> Bool {
        guard let root, busy == nil, !isLoading else { return false }
        let output = try? await fs.run(#"""
            cd "$P" || exit
            {
                git status --porcelain=v1 -z --untracked-files=all 2>/dev/null
                git rev-parse HEAD 2>/dev/null
                git for-each-ref --format='%(refname) %(objectname)' 2>/dev/null
                # GNU stat, else BSD's (macOS).
                st() { stat -c "$1" -- "$3" 2>/dev/null || stat -f "$2" -- "$3" 2>/dev/null; }
                printf '%s\n' "$DIRS" | while IFS= read -r d; do [ -n "$d" ] && st '%n %Y' '%N %m' "$d"; done
                printf '%s\n' "$FILES" | while IFS= read -r f; do [ -n "$f" ] && st '%n %Y %s' '%N %m %z' "$f"; done
            } | cksum
            """#, ["P": root, "DIRS": ([root] + expanded.sorted()).joined(separator: "\n"), "FILES": openFiles.joined(separator: "\n")])
        guard let current = output?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty else { return false }
        defer { fingerprint = current }
        return fingerprint != nil && fingerprint != current
    }

    // MARK: Tree

    func toggle(_ entry: RemoteFS.Entry) async {
        guard entry.isDirectory else { return }
        if expanded.remove(entry.path) == nil {
            expanded.insert(entry.path)
            if children[entry.path] == nil {
                children[entry.path] = (try? await fs.list(entry.path)) ?? []
            }
        }
        rebuildRows()
    }

    func isExpanded(_ entry: RemoteFS.Entry) -> Bool {
        expanded.contains(entry.path)
    }

    /// Git letter for a file, or "•" for a folder containing changes.
    func badge(for entry: RemoteFS.Entry) -> Character? {
        entry.isDirectory ? (changedFolders.contains(entry.path) ? "•" : nil) : letters[entry.path]
    }

    private func rebuildRows() {
        var result: [Row] = []
        func add(_ path: String, depth: Int) {
            for entry in children[path] ?? [] {
                result.append(Row(entry: entry, depth: depth))
                if entry.isDirectory, expanded.contains(entry.path) {
                    add(entry.path, depth: depth + 1)
                }
            }
        }
        if let root { add(root, depth: 0) }
        rows = result
    }

    // MARK: Git

    private func refreshGitStatus() async {
        guard isRepository, let root else {
            changes = []
            letters = [:]
            changedFolders = []
            return
        }
        let output = (try? await fs.run(
            #"cd "$P" && git status --porcelain=v1 -z --untracked-files=all"#, ["P": root]
        )) ?? ""
        var parsed: [Change] = []
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let field = fields.popFirst(), field.count > 3 {
            let x = field[field.startIndex]
            let y = field[field.index(after: field.startIndex)]
            let relative = String(field.dropFirst(3))
            if x == "R" || x == "C" { _ = fields.popFirst() } // the original name follows a rename
            let letter: Character = switch (x, y) {
            case ("?", "?"): "U"
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): "C"
            case (_, "D"), ("D", _): "D"
            case ("A", _): "A"
            case ("R", _): "R"
            default: "M"
            }
            parsed.append(Change(path: root + "/" + relative, relativePath: relative, letter: letter,
                                 indexStatus: x, worktreeStatus: y))
        }
        changes = parsed.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        letters = Dictionary(parsed.map { ($0.path, $0.letter) }, uniquingKeysWith: { a, _ in a })
        var folders = Set<String>()
        for change in parsed {
            var folder = (change.path as NSString).deletingLastPathComponent
            while folder.count > root.count {
                folders.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        changedFolders = folders
    }

    /// A file's diff: against HEAD, staged only or unstaged only. Untracked files show as all-added.
    func diff(for change: Change, scope: DiffScope = .head) async throws -> String {
        guard let root else { return "" }
        let script: String
        if change.letter == "U" {
            script = #"cd "$P" && git diff --no-color --no-index -- /dev/null "$F""#
        } else {
            switch scope {
            case .head: script = #"cd "$P" && git diff --no-color HEAD -- "$F""#
            case .staged: script = #"cd "$P" && git diff --no-color --cached -- "$F""#
            case .unstaged: script = #"cd "$P" && git diff --no-color -- "$F""#
            }
        }
        return try await fs.run(script, ["P": root, "F": change.relativePath])
    }

    func show(_ commit: Commit) async throws -> String {
        guard let root else { return "" }
        return try await fs.run(#"cd "$P" && git show --no-color --stat --patch "$C""#, ["P": root, "C": commit.sha])
    }

    /// Recent commits on every local branch (and HEAD), newest first in topological order,
    /// with the graph laid out for them.
    private func refreshCommits() async {
        guard isRepository, let root else {
            commits = []
            graph = []
            return
        }
        let output = (try? await fs.run(
            #"cd "$P" && git log --decorate=full --topo-order --branches HEAD -80 --format='%H%x1f%P%x1f%s%x1f%cr%x1f%an%x1f%D'"#, ["P": root]
        )) ?? ""
        commits = output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6 else { return nil }
            return Commit(sha: fields[0], parents: fields[1].split(separator: " ").map(String.init), subject: fields[2],
                          age: fields[3], author: fields[4],
                          refs: fields[5].isEmpty ? [] : fields[5].components(separatedBy: ", "))
        }
        graph = CommitGraph.layout(commits)
    }

    /// What `commit` changed, against its first parent (the empty tree for a root commit).
    func files(in commit: Commit) async throws -> [CommitFile] {
        guard let root else { return [] }
        let output = try await fs.run(
            #"cd "$P" && git diff --no-color --name-status -z -M "${B:-$(git hash-object -t tree /dev/null)}" "$C""#,
            ["P": root, "C": commit.sha, "B": commit.parents.first ?? ""]
        )
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        var files: [CommitFile] = []
        while let status = fields.popFirst(), let letter = status.first {
            if letter == "R" || letter == "C" {
                guard let old = fields.popFirst(), let new = fields.popFirst() else { break }
                files.append(CommitFile(path: new, oldPath: old, letter: letter))
            } else {
                guard let path = fields.popFirst() else { break }
                files.append(CommitFile(path: path, oldPath: path, letter: letter))
            }
        }
        return files
    }

    /// A commit file's unified diff, for the inline view.
    func diff(for file: CommitFile, in commit: Commit) async throws -> String {
        guard let root else { return "" }
        return try await fs.run(
            #"cd "$P" && git diff --no-color -M "${B:-$(git hash-object -t tree /dev/null)}" "$C" -- "$O" "$F""#,
            ["P": root, "C": commit.sha, "B": commit.parents.first ?? "", "O": file.oldPath, "F": file.path]
        )
    }

    /// One version of a file (`relativePath` from the repository root), or nil when it doesn't
    /// exist there (added, deleted, untracked).
    func contents(of relativePath: String, at revision: Revision) async throws -> RemoteFS.ReadResult? {
        guard let root else { return nil }
        let object: String
        switch revision {
        case .worktree:
            return try? await fs.read(root + "/" + relativePath)
        case .index: object = ":" + relativePath
        case .commit(let sha): object = sha + ":" + relativePath
        }
        // A one-line header (size, or "-" when missing) keeps big blobs from being sent at all.
        let data = try await fs.runData(
            #"cd "$P" && S=$(git cat-file -s "$O" 2>/dev/null) || { echo -; exit; }; echo "$S"; [ "$S" -le "$M" ] && git cat-file blob "$O""#,
            ["P": root, "O": object, "M": String(RemoteFS.maxPreviewBytes)]
        )
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        let header = String(decoding: data[..<newline], as: UTF8.self)
        guard let size = UInt64(header) else { return nil }
        guard size <= RemoteFS.maxPreviewBytes else { return .tooLarge(size: size) }
        let body = data[data.index(after: newline)...]
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) { return .image(Data(body)) }
        if body.prefix(8192).contains(0) { return .binary(size: size) }
        return .text(String(decoding: body, as: UTF8.self))
    }

    /// The two versions a working-tree change compares: (before, after).
    func revisions(for change: Change, scope: DiffScope) -> (old: Revision?, new: Revision?) {
        let untracked = change.letter == "U"
        let added = change.indexStatus == "A" || untracked
        switch scope {
        case .head: return (added ? nil : .commit("HEAD"), change.worktreeStatus == "D" || (change.indexStatus == "D" && change.worktreeStatus == " ") ? nil : .worktree)
        case .staged: return (added ? nil : .commit("HEAD"), change.indexStatus == "D" ? nil : .index)
        case .unstaged: return (untracked ? nil : .index, change.worktreeStatus == "D" ? nil : .worktree)
        }
    }

    private func refreshBranch() async {
        guard isRepository, let root else {
            branch = nil
            upstream = nil
            ahead = 0
            behind = 0
            localBranches = []
            isMerging = false
            hasStash = false
            return
        }
        let output = (try? await fs.run(#"""
            cd "$P" || exit
            printf 'branch=%s\n' "$(git symbolic-ref -q --short HEAD)"
            printf 'upstream=%s\n' "$(git rev-parse -q --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
            printf 'counts=%s\n' "$(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)"
            [ -e "$(git rev-parse --git-path MERGE_HEAD)" ] && echo merging=1
            git rev-parse -q --verify refs/stash >/dev/null && echo stash=1
            git for-each-ref --format='local=%(refname:short)' refs/heads
            """#, ["P": root])) ?? ""
        var branches: [String] = []
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if key == "local" { branches.append(value) } else { values[key] = value }
        }
        branch = values["branch"].flatMap { $0.isEmpty ? nil : $0 }
        upstream = values["upstream"].flatMap { $0.isEmpty ? nil : $0 }
        let counts = (values["counts"] ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        behind = counts.count == 2 ? counts[0] : 0
        ahead = counts.count == 2 ? counts[1] : 0
        isMerging = values["merging"] != nil
        hasStash = values["stash"] != nil
        localBranches = branches
    }

    // MARK: Git operations

    /// Runs a git `script` in the repository, then refreshes everything. Failures put git's
    /// output in `failure`. Nothing can prompt (no terminal): credentials must already work.
    @discardableResult
    func perform(_ label: String, _ script: String, _ variables: [String: String] = [:]) async -> Bool {
        guard let root, busy == nil else { return false }
        busy = label
        var environment = variables
        environment["P"] = root
        let marker = "__AGENTTERM_EXIT__"
        let output: String
        do {
            output = try await fs.run(#"""
                cd "$P" || exit 1
                export GIT_TERMINAL_PROMPT=0 GIT_EDITOR=true GIT_MERGE_AUTOEDIT=no
                {
                """# + "\n" + script + "\n" + #"""
                } 2>&1
                echo "__AGENTTERM_EXIT__$?"
                """#, environment)
        } catch {
            output = error.localizedDescription + "\n" + marker + "1"
        }
        let code = output.range(of: marker, options: .backwards).flatMap { Int(output[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        let text = output.range(of: marker, options: .backwards).map { String(output[..<$0.lowerBound]) } ?? output
        busy = nil
        if code != 0 {
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            failure = message.isEmpty ? "\(label.replacingOccurrences(of: "…", with: "")) failed (git exited with \(code))." : message
        }
        await refresh()
        return code == 0
    }

    func stage(_ change: Change) async {
        await perform("Staging…", #"git add -A -- "$F""#, ["F": change.relativePath])
    }

    func unstage(_ change: Change) async {
        // `git rm --cached` only for a repository with no commits yet (no HEAD to restore from).
        await perform("Unstaging…", #"if git rev-parse -q --verify HEAD >/dev/null; then git restore --staged -- "$F"; else git rm -q --cached -- "$F"; fi"#,
                      ["F": change.relativePath])
    }

    /// Throws away the file's unstaged changes; an untracked file is deleted.
    func discard(_ change: Change) async {
        let script = change.letter == "U" ? #"git clean -f -q -- "$F""# : #"git restore --worktree -- "$F""#
        await perform("Discarding…", script, ["F": change.relativePath])
    }

    func stageAll() async {
        await perform("Staging…", "git add -A")
    }

    func unstageAll() async {
        await perform("Unstaging…", "if git rev-parse -q --verify HEAD >/dev/null; then git restore --staged -- :/; else git rm -r -q --cached -- :/; fi")
    }

    /// Every unstaged change thrown away and untracked files deleted (ignored files stay).
    func discardAll() async {
        await perform("Discarding…", "git restore --worktree -- :/ && git clean -fd -q -- :/")
    }

    /// Commits the staged changes (or everything, with `all`), optionally amending the last
    /// commit and pushing after.
    @discardableResult
    func commit(message: String, all: Bool = false, amend: Bool = false, push: Bool = false) async -> Bool {
        var script = all ? "git add -A && " : ""
        if amend, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            script += "git commit -q --amend --no-edit"
        } else {
            script += #"printf '%s\n' "$M" | git commit -q \#(amend ? "--amend " : "")-F -"#
        }
        if push { script += " && " + Self.pushScript }
        return await perform(push ? "Committing and pushing…" : "Committing…", script, ["M": message])
    }

    func fetch() async {
        await perform("Fetching…", Self.timeLimit + "git fetch --all --prune")
    }

    func pull() async {
        await perform("Pulling…", Self.timeLimit + "git pull --no-edit")
    }

    /// Pushes, setting the upstream on the first push of a new branch.
    /// Network git commands give up after two minutes where `timeout` exists (GNU; macOS
    /// lacks it), rather than hang on a prompt or a dead remote.
    private static let timeLimit = #"$(command -v timeout >/dev/null 2>&1 && echo "timeout 120") "#

    private static let pushScript = #"TL=$(command -v timeout >/dev/null 2>&1 && echo "timeout 120"); if git rev-parse -q --verify '@{u}' >/dev/null 2>&1; then $TL git push; else $TL git push -u "$(git remote | head -n 1)" HEAD; fi"#

    func push() async {
        await perform("Pushing…", Self.pushScript)
    }

    /// Pull then push, as VS Code's Sync.
    func sync() async {
        await perform("Syncing…", Self.timeLimit + "git pull --no-edit && " + Self.pushScript)
    }

    func switchBranch(_ name: String) async {
        await perform("Switching branch…", #"git switch "$B""#, ["B": name])
    }

    /// A new branch at HEAD (or `commit`), switched to.
    func createBranch(_ name: String, at commit: Commit? = nil) async {
        await perform("Creating branch…", #"git switch -c "$B" ${C:+"$C"}"#, ["B": name, "C": commit?.sha ?? ""])
    }

    func checkoutDetached(_ commit: Commit) async {
        await perform("Checking out…", #"git switch --detach "$C""#, ["C": commit.sha])
    }

    func revert(_ commit: Commit) async {
        await perform("Reverting…", #"git revert --no-edit "$C""#, ["C": commit.sha])
    }

    func stash() async {
        await perform("Stashing…", "git stash push -u -q -m 'AgentTerm'")
    }

    func popStash() async {
        await perform("Popping stash…", "git stash pop -q")
    }

    /// Undoes the last commit, keeping its changes staged. Returns its message (for the
    /// commit box, as VS Code does).
    func undoLastCommit() async -> String? {
        guard let root else { return nil }
        let message = try? await fs.run(#"cd "$P" && git log -1 --format=%B"#, ["P": root])
        guard await perform("Undoing commit…", "git reset -q --soft HEAD~1") else { return nil }
        return message?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func abortMerge() async {
        await perform("Aborting merge…", "git merge --abort")
    }

    /// `path` relative to the pane's directory when it's inside it (Claude Code's working
    /// directory, usually), else absolute.
    func displayPath(_ path: String) -> String {
        if let pane = paneDirectory, path.hasPrefix(pane + "/") { return String(path.dropFirst(pane.count + 1)) }
        return path
    }

    func change(for path: String) -> Change? {
        changes.first { $0.path == path }
    }

    func close() {
        let fs = self.fs
        Task { await fs.close() }
    }
}
