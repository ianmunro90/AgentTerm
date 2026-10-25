import SwiftUI

/// The editor's side bar: an activity strip (Explorer, Source Control, Terminal) over the
/// chosen activity's list, like VS Code's.
struct EditorSidebar: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var explorer: ExplorerModel
    let onTerminal: () -> Void
    let onKey: () -> Void
    let onSettings: () -> Void
    @EnvironmentObject private var settings: AppSettings

    /// Same theme as the editor area and the terminal.
    private var theme: TerminalTheme { settings.theme(for: workspace.session.host) }

    init(workspace: EditorWorkspace, onTerminal: @escaping () -> Void, onKey: @escaping () -> Void,
         onSettings: @escaping () -> Void) {
        self.workspace = workspace
        explorer = workspace.explorer
        self.onTerminal = onTerminal
        self.onKey = onKey
        self.onSettings = onSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            activityBar
            Divider()
            Group {
                switch workspace.activity {
                case .explorer: ExplorerList(workspace: workspace, explorer: explorer)
                case .search: SearchPanel(workspace: workspace, search: workspace.search)
                case .sourceControl: SourceControlList(workspace: workspace, explorer: explorer)
                }
            }
            .scrollContentBackground(.hidden)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter(onKey: onKey, onSettings: onSettings, background: Color(uiColor: theme.editorChrome(0.05)))
            }
        }
        .background(Color(uiColor: theme.editorChrome(0.05)))
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        .environment(\.editorTheme, theme)
        .toolbarColorScheme(theme.isLight ? .light : .dark, for: .navigationBar)
        .navigationTitle(explorer.root.map { ($0 as NSString).lastPathComponent } ?? "Editor")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var activityBar: some View {
        HStack(spacing: 4) {
            activityButton(.explorer, "Explorer", "doc.on.doc")
            activityButton(.search, "Search", "magnifyingglass")
                .keyboardShortcut("f", modifiers: [.command, .shift])
            activityButton(.sourceControl, "Source Control", "arrow.triangle.branch", badge: explorer.changes.count)
            Spacer()
            Button(action: onTerminal) {
                Label("Terminal", systemImage: "terminal").labelStyle(.iconOnly).frame(width: 40, height: 34)
            }
            .help("Terminal (⌃`)")
        }
        .font(.system(size: 17))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .buttonStyle(.plain)
    }

    private func activityButton(_ activity: EditorWorkspace.Activity, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        Button {
            workspace.activity = activity
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .foregroundStyle(workspace.activity == activity ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 40, height: 34)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 4)
                            .background(.tint, in: Capsule())
                            .foregroundStyle(.white)
                            .offset(x: 2, y: 2)
                    }
                }
                .background(workspace.activity == activity ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .help(title)
    }
}

// MARK: - Explorer

private struct ExplorerList: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var explorer: ExplorerModel

    /// A file with errors (warnings aren't marked), or a folder with one below it.
    private func hasErrors(_ entry: RemoteFS.Entry) -> Bool {
        if entry.isDirectory { return workspace.errorFolders.contains(entry.path) }
        return workspace.diagnostics[entry.path]?.contains { $0.severity == .error } ?? false
    }

    var body: some View {
        // Full-width rows, sized like Source Control's (not the inset system sidebar list).
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FolderHeader(explorer: explorer)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                ForEach(explorer.rows) { row in
                    let isOpen = workspace.selectedTab?.path == row.entry.path
                    Button {
                        if row.entry.isDirectory {
                            Task { await explorer.toggle(row.entry) }
                        } else {
                            workspace.openFromExplorer(row.entry.path)
                        }
                    } label: {
                        TreeRow(row: row, isExpanded: explorer.isExpanded(row.entry), badge: explorer.badge(for: row.entry),
                                isOpen: isOpen, hasErrors: hasErrors(row.entry))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 30)
                            .background(isOpen ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !row.entry.isDirectory {
                            Button("Open", systemImage: "doc.text") { workspace.open(.file, path: row.entry.path, pinned: true) }
                            if let change = explorer.change(for: row.entry.path) {
                                Button("Open Changes", systemImage: "plusminus") {
                                    workspace.open(.diff(change, .head), path: row.entry.path, pinned: true)
                                }
                                if change.hasUnstaged {
                                    Button("Stage Changes", systemImage: "plus") { Task { await explorer.stage(change) } }
                                }
                            }
                        }
                        Button("Ask Claude About This", systemImage: "sparkles") { workspace.askAboutFile(row.entry.path) }
                        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.entry.path }
                    }
                }
                if let error = explorer.error {
                    Text(error).foregroundStyle(.red).font(.callout).padding(12)
                }
            }
            .padding(.bottom, 12)
        }
        .refreshable { await explorer.refresh() }
        .overlay {
            if explorer.isLoading && explorer.rows.isEmpty { ProgressView() }
        }
    }
}

private struct FolderHeader: View {
    @ObservedObject var explorer: ExplorerModel

    var body: some View {
        HStack(spacing: 10) {
            Text(explorer.root ?? "")
                .font(.caption2.monospaced())
                .textCase(nil)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Parent Folder", systemImage: "arrow.up") { Task { await explorer.openParent() } }
            Button("Follow Pane", systemImage: "scope") { Task { await explorer.followPane() } }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await explorer.refresh() } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Source Control

/// Staged and unstaged changes over a commit graph, VS Code style. Tapping a commit lists its
/// files; tapping a file compares it with the commit's parent.
private struct SourceControlList: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var explorer: ExplorerModel
    @Environment(\.editorTheme) private var theme
    @State private var collapsed: Set<String> = []
    @State private var confirmation: Confirmation?
    @State private var branchPrompt: BranchPrompt?
    @State private var branchName = ""

    /// Destructive or surprising actions, confirmed first.
    enum Confirmation: Identifiable {
        case discard(ExplorerModel.Change)
        case discardAll(changed: Int, untracked: Int)
        case stageAllAndCommit
        case undoCommit
        case revert(ExplorerModel.Commit)
        case abortMerge

        var id: String {
            switch self {
            case .discard(let change): "discard " + change.path
            case .discardAll: "discardAll"
            case .stageAllAndCommit: "stageAllAndCommit"
            case .undoCommit: "undo"
            case .revert(let commit): "revert " + commit.sha
            case .abortMerge: "abortMerge"
            }
        }
    }

    /// Asking for a new branch's name (at HEAD, or at a commit).
    struct BranchPrompt: Identifiable {
        let commit: ExplorerModel.Commit?
        var id: String { commit?.sha ?? "HEAD" }
    }

    private var staged: [ExplorerModel.Change] { explorer.changes.filter(\.isStaged) }
    private var unstaged: [ExplorerModel.Change] { explorer.changes.filter(\.hasUnstaged) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !explorer.isRepository {
                    Text("Not a git repository").foregroundStyle(.secondary).padding()
                } else {
                    commitBox
                    if explorer.isMerging {
                        Label("Merging: resolve the conflicts, stage them and commit, or abort.", systemImage: "arrow.triangle.merge")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                    if !staged.isEmpty {
                        section("Staged Changes", count: staged.count) {
                            sectionButton("Unstage All", "minus") { Task { await explorer.unstageAll() } }
                        } content: {
                            ForEach(staged) { change in changeRow(change, scope: .staged) }
                        }
                    }
                    section("Changes", count: unstaged.count) {
                        if !unstaged.isEmpty {
                            sectionButton("Discard All Changes", "arrow.uturn.backward") {
                                let untracked = unstaged.filter { $0.letter == "U" }.count
                                confirmation = .discardAll(changed: unstaged.count - untracked, untracked: untracked)
                            }
                            sectionButton("Stage All Changes", "plus") { Task { await explorer.stageAll() } }
                        }
                    } content: {
                        ForEach(unstaged) { change in changeRow(change, scope: .unstaged) }
                    }
                    if !explorer.commits.isEmpty {
                        section("Graph", count: nil) {
                            sectionButton("Fetch", "arrow.triangle.2.circlepath") { Task { await explorer.fetch() } }
                            sectionButton("Pull", "arrow.down") { Task { await explorer.pull() } }
                            sectionButton("Push", "arrow.up") { Task { await explorer.push() } }
                            branchMenu
                        } content: {
                            graph
                        }
                    }
                }
            }
            .padding(.bottom, 12)
            // One git operation at a time (the list still scrolls).
            .disabled(explorer.busy != nil)
        }
        .refreshable { await explorer.refresh() }
        .confirmationDialog(confirmationTitle, isPresented: isPresented($confirmation), titleVisibility: .visible,
                            presenting: confirmation) { action in
            confirmationButtons(action)
        } message: { action in
            Text(confirmationMessage(action))
        }
        .alert("New Branch", isPresented: isPresented($branchPrompt), presenting: branchPrompt) { prompt in
            TextField("Branch name", text: $branchName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create and Switch") {
                let name = branchName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task { await explorer.createBranch(name, at: prompt.commit) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            Text(prompt.commit.map { "From \($0.shortSHA) “\($0.subject)”." } ?? "From the current commit. Uncommitted changes come along.")
        }
        .alert("Git", isPresented: Binding(get: { explorer.failure != nil }, set: { if !$0 { explorer.failure = nil } }),
               presenting: explorer.failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure)
        }
    }

    private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    // MARK: Commit box

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(explorer.branch ?? "Detached HEAD").fontWeight(.semibold).lineLimit(1)
                if explorer.upstream != nil, explorer.ahead + explorer.behind > 0 {
                    Text("↓\(explorer.behind) ↑\(explorer.ahead)").monospacedDigit().foregroundStyle(.secondary)
                } else if explorer.branch != nil, explorer.upstream == nil {
                    Text("not published").foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = explorer.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            TextField(commitPlaceholder, text: $workspace.commitMessage, axis: .vertical)
                .lineLimit(1...8)
                .font(.callout)
                .padding(8)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 0) {
                Button(action: primaryAction) {
                    Label(primaryTitle, systemImage: primaryIcon)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!primaryEnabled)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 22)
                Menu {
                    commitMenu
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 36, height: 34)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .background(.tint.opacity(primaryEnabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: 8))

            Button {
                workspace.reviewAllChanges()
            } label: {
                Label("Ask Claude to Review Changes", systemImage: "sparkles")
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(explorer.changes.isEmpty)
            .opacity(explorer.changes.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var commitPlaceholder: String {
        "Message (⌘↩ to commit" + (explorer.branch.map { " on “\($0)”" } ?? "") + ")"
    }

    private var hasMessage: Bool { !workspace.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// VS Code's button: Commit while there are changes; with none, Sync or Publish.
    private enum Primary { case commit, sync, publish }

    private var primary: Primary {
        if !explorer.changes.isEmpty || hasMessage { return .commit }
        if explorer.branch != nil, explorer.upstream == nil { return .publish }
        if explorer.ahead + explorer.behind > 0 { return .sync }
        return .commit
    }

    private var primaryTitle: String {
        switch primary {
        case .commit: "Commit"
        case .sync: "Sync Changes ↓\(explorer.behind) ↑\(explorer.ahead)"
        case .publish: "Publish Branch"
        }
    }

    private var primaryIcon: String {
        switch primary {
        case .commit: "checkmark"
        case .sync: "arrow.triangle.2.circlepath"
        case .publish: "icloud.and.arrow.up"
        }
    }

    private var primaryEnabled: Bool {
        guard explorer.busy == nil else { return false }
        switch primary {
        case .commit: return hasMessage && !explorer.changes.isEmpty
        case .sync, .publish: return true
        }
    }

    private func primaryAction() {
        switch primary {
        case .commit:
            if staged.isEmpty {
                confirmation = .stageAllAndCommit
            } else {
                Task { await workspace.commit() }
            }
        case .sync: Task { await explorer.sync() }
        case .publish: Task { await explorer.push() }
        }
    }

    @ViewBuilder
    private var commitMenu: some View {
        Section {
            Button("Commit Staged", systemImage: "checkmark") { Task { await workspace.commit() } }
                .disabled(!hasMessage || staged.isEmpty)
            Button("Commit Staged & Push", systemImage: "arrow.up.circle") { Task { await workspace.commit(push: true) } }
                .disabled(!hasMessage || staged.isEmpty)
            Button("Commit All", systemImage: "checkmark.circle") { Task { await workspace.commit(all: true) } }
                .disabled(!hasMessage || explorer.changes.isEmpty)
            Button("Commit All & Push", systemImage: "arrow.up.circle.fill") { Task { await workspace.commit(all: true, push: true) } }
                .disabled(!hasMessage || explorer.changes.isEmpty)
        }
        Section {
            Button("Amend Last Commit", systemImage: "pencil") { Task { await workspace.commit(amend: true) } }
            Button("Undo Last Commit", systemImage: "arrow.uturn.backward") { confirmation = .undoCommit }
        }
        Section {
            Button("Ask Claude to Commit", systemImage: "sparkles") { workspace.askClaudeToCommit() }
                .disabled(staged.isEmpty)
        }
    }

    // MARK: Branches

    private var branchMenu: some View {
        Menu {
            Section {
                Button("Sync (Pull, then Push)", systemImage: "arrow.triangle.2.circlepath") { Task { await explorer.sync() } }
            }
            Section {
                Menu("Switch Branch", systemImage: "arrow.triangle.branch") {
                    ForEach(explorer.localBranches, id: \.self) { name in
                        Button(name, systemImage: name == explorer.branch ? "checkmark" : "") {
                            Task { await explorer.switchBranch(name) }
                        }
                        .disabled(name == explorer.branch)
                    }
                }
                Button("New Branch…", systemImage: "plus") {
                    branchName = ""
                    branchPrompt = BranchPrompt(commit: nil)
                }
            }
            Section {
                Button("Stash Changes", systemImage: "tray.and.arrow.down") { Task { await explorer.stash() } }
                    .disabled(explorer.changes.isEmpty)
                Button("Pop Stash", systemImage: "tray.and.arrow.up") { Task { await explorer.popStash() } }
                    .disabled(!explorer.hasStash)
            }
            if explorer.isMerging {
                Button("Abort Merge", systemImage: "xmark.octagon", role: .destructive) { confirmation = .abortMerge }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
    }

    // MARK: Sections

    private func section<Accessory: View, Content: View>(_ title: String, count: Int?,
                                                        @ViewBuilder accessory: () -> Accessory,
                                                        @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.contains(title)
        return Group {
            HStack(spacing: 6) {
                Button {
                    if collapsed.remove(title) == nil { collapsed.insert(title) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text(title.uppercased())
                        if let count { Text("\(count)").monospacedDigit() }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                accessory()
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if !isCollapsed { content() }
        }
    }

    private func sectionButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .frame(width: 26, height: 22)
            .contentShape(Rectangle())
            .help(title)
    }

    private func isSelected(_ kind: EditorWorkspace.Tab.Kind, path: String) -> Bool {
        workspace.selectedTabID == EditorWorkspace.Tab(kind: kind, path: path, isPreview: true).id
    }

    private func changeRow(_ change: ExplorerModel.Change, scope: ExplorerModel.DiffScope) -> some View {
        let letter = scope == .staged ? Self.letter(change.indexStatus) : change.letter
        return HStack(spacing: 2) {
            Button {
                workspace.open(.diff(change, scope), path: change.path)
            } label: {
                HStack(spacing: 6) {
                    FileIcon(name: change.name)
                    Text(change.name)
                        .lineLimit(1)
                        .strikethrough(letter == "D")
                        .foregroundStyle(GitBadge.color(for: letter, theme: theme))
                    Text(change.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Group {
                if scope == .staged {
                    Button("Unstage", systemImage: "minus") { Task { await explorer.unstage(change) } }
                } else {
                    Button("Discard Changes", systemImage: "arrow.uturn.backward") { confirmation = .discard(change) }
                    Button("Stage", systemImage: "plus") { Task { await explorer.stage(change) } }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            GitBadge(letter: letter).frame(width: 14)
        }
        .font(.callout)
        .padding(.leading, 30)
        .padding(.trailing, 12)
        .background(isSelected(.diff(change, scope), path: change.path) ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        .contextMenu {
            if scope == .staged {
                Button("Unstage", systemImage: "minus") { Task { await explorer.unstage(change) } }
            } else {
                Button("Stage", systemImage: "plus") { Task { await explorer.stage(change) } }
            }
            Button("Open File", systemImage: "doc.text") { workspace.open(.file, path: change.path, pinned: true) }
            Button("Ask Claude to Review", systemImage: "sparkles") { workspace.reviewChange(change, scope: scope) }
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = change.path }
            if scope != .staged {
                Divider()
                Button(change.letter == "U" ? "Delete File" : "Discard Changes", systemImage: "arrow.uturn.backward",
                       role: .destructive) { confirmation = .discard(change) }
            }
        }
    }

    // MARK: Confirmations

    private var confirmationTitle: String {
        switch confirmation {
        case .discard(let change)?: change.letter == "U" ? "Delete \(change.name)?" : "Discard changes to \(change.name)?"
        case .discardAll?: "Discard all changes?"
        case .stageAllAndCommit?: "No staged changes"
        case .undoCommit?: "Undo the last commit?"
        case .revert?: "Revert this commit?"
        case .abortMerge?: "Abort the merge?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ action: Confirmation) -> String {
        switch action {
        case .discard(let change):
            change.letter == "U" ? "The file isn't tracked by git, so it can't be recovered."
                : "Its unstaged changes are lost; staged changes stay."
        case .discardAll(let changed, let untracked):
            "\(changed) changed file\(changed == 1 ? "" : "s") go back to their staged or committed state"
                + (untracked > 0 ? " and \(untracked) untracked file\(untracked == 1 ? " is" : "s are") deleted" : "")
                + ". This can't be undone."
        case .stageAllAndCommit: "Stage all changes (including untracked files) and commit them?"
        case .undoCommit: "Its changes stay staged and its message goes back in the box."
        case .revert(let commit): "A new commit undoes \(commit.shortSHA) “\(commit.subject)”."
        case .abortMerge: "The merge's changes and any conflict resolutions are thrown away."
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ action: Confirmation) -> some View {
        switch action {
        case .discard(let change):
            Button(change.letter == "U" ? "Delete File" : "Discard Changes", role: .destructive) {
                Task { await explorer.discard(change) }
            }
        case .discardAll:
            Button("Discard All", role: .destructive) { Task { await explorer.discardAll() } }
        case .stageAllAndCommit:
            Button("Stage All and Commit") { Task { await workspace.commit(all: true) } }
        case .undoCommit:
            Button("Undo Commit", role: .destructive) { Task { await workspace.undoLastCommit() } }
        case .revert(let commit):
            Button("Revert") { Task { await explorer.revert(commit) } }
        case .abortMerge:
            Button("Abort Merge", role: .destructive) { Task { await explorer.abortMerge() } }
        }
        Button("Cancel", role: .cancel) {}
    }

    // MARK: Graph

    private static let laneWidth: CGFloat = 12

    private var graphWidth: CGFloat {
        CGFloat(min(explorer.graph.map(\.width).max() ?? 1, 6)) * Self.laneWidth + 10
    }

    @ViewBuilder
    private var graph: some View {
        let rows = explorer.graph
        ForEach(Array(explorer.commits.enumerated()), id: \.element.id) { index, commit in
            if rows.indices.contains(index) {
                commitRow(commit, graph: rows[index])
                if workspace.expandedCommits.contains(commit.sha) {
                    commitFiles(commit, graph: rows[index])
                }
            }
        }
    }

    private func commitRow(_ commit: ExplorerModel.Commit, graph row: CommitGraph.Row) -> some View {
        let expanded = workspace.expandedCommits.contains(commit.sha)
        return Button {
            workspace.toggleCommit(commit)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ForEach(RefLabel.parse(commit.refs), id: \.name) { ref in
                        RefBadge(ref: ref, color: GraphLines.color(row.lane, theme: theme))
                    }
                    Text(commit.subject)
                        .lineLimit(1)
                        .fontWeight(commit.isHead ? .semibold : .regular)
                }
                Text("\(commit.author) · \(commit.age)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.callout)
            .padding(.vertical, 5)
            .padding(.leading, graphWidth + 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                GraphLines(row: row, theme: theme, mode: .commit(isHead: commit.isHead, isMerge: commit.parents.count > 1))
                    .frame(width: graphWidth)
                    .padding(.leading, 8)
            }
            .background(expanded ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show Full Commit", systemImage: "text.alignleft") { workspace.open(.commit(commit), path: commit.sha, pinned: true) }
            Button("Ask Claude to Review", systemImage: "sparkles") { workspace.reviewCommit(commit) }
            Button("Copy Hash", systemImage: "doc.on.doc") { UIPasteboard.general.string = commit.sha }
            Divider()
            Button("Create Branch Here…", systemImage: "arrow.triangle.branch") {
                branchName = ""
                branchPrompt = BranchPrompt(commit: commit)
            }
            Button("Check Out (Detached)", systemImage: "arrow.uturn.right") { Task { await explorer.checkoutDetached(commit) } }
            Button("Revert Commit…", systemImage: "arrow.uturn.backward") { confirmation = .revert(commit) }
        }
    }

    @ViewBuilder
    private func commitFiles(_ commit: ExplorerModel.Commit, graph row: CommitGraph.Row) -> some View {
        let lines = GraphLines(row: row, theme: theme, mode: .through)
        if let files = workspace.commitFiles[commit.sha] {
            if files.isEmpty {
                Text("No file changes")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .padding(.leading, graphWidth + 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(alignment: .leading) { lines.frame(width: graphWidth).padding(.leading, 8) }
            }
            ForEach(files) { file in
                let path = (explorer.root ?? "") + "/" + file.path
                Button {
                    workspace.openFile(in: commit, file)
                } label: {
                    FileRow(name: file.name, folder: file.folder, letter: file.letter, strike: file.letter == "D",
                            isSelected: isSelected(.commitFile(commit, file), path: path))
                        .padding(.leading, graphWidth + 4)
                        .background(alignment: .leading) { lines.frame(width: graphWidth).padding(.leading, 8) }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Open File", systemImage: "doc.text") { workspace.open(.file, path: path, pinned: true) }
                    Button("Ask Claude About This File", systemImage: "sparkles") { workspace.askAboutFile(path) }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .padding(.vertical, 6)
                .padding(.leading, graphWidth + 26)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) { lines.frame(width: graphWidth).padding(.leading, 8) }
        }
    }

    private static func letter(_ status: Character) -> Character {
        switch status {
        case "A": "A"
        case "D": "D"
        case "R": "R"
        default: "M"
        }
    }
}

/// A changed file in the Source Control panel: icon, name, folder, status letter.
private struct FileRow: View {
    let name: String
    let folder: String
    let letter: Character
    var strike = false
    var isSelected = false
    @Environment(\.editorTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: name)
            Text(name)
                .lineLimit(1)
                .strikethrough(strike)
                .foregroundStyle(GitBadge.color(for: letter, theme: theme))
            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            GitBadge(letter: letter)
        }
        .font(.callout)
        .padding(.trailing, 12)
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
    }
}

/// A branch or tag name shown on a commit.
private struct RefLabel {
    let name: String
    let isHead: Bool
    let isTag: Bool
    let isRemote: Bool

    /// Full `%D` entries: "HEAD -> refs/heads/main", "refs/remotes/origin/main",
    /// "tag: refs/tags/v1.0", "HEAD" (detached).
    static func parse(_ refs: [String]) -> [RefLabel] {
        var labels: [RefLabel] = []
        for ref in refs {
            var name = Substring(ref)
            let isHead = name == "HEAD" || name.hasPrefix("HEAD -> ")
            if name.hasPrefix("HEAD -> ") { name = name.dropFirst(8) }
            if name.hasPrefix("tag: ") { name = name.dropFirst(5) }
            if name.hasPrefix("refs/remotes/"), name.hasSuffix("/HEAD") { continue }
            let isTag = name.hasPrefix("refs/tags/")
            let isRemote = name.hasPrefix("refs/remotes/")
            for prefix in ["refs/heads/", "refs/tags/", "refs/remotes/"] where name.hasPrefix(prefix) {
                name = name.dropFirst(prefix.count)
            }
            labels.append(RefLabel(name: String(name), isHead: isHead, isTag: isTag, isRemote: isRemote))
        }
        return labels
    }
}

private struct RefBadge: View {
    let ref: RefLabel
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: ref.isTag ? "tag" : ref.isRemote ? "cloud" : ref.isHead ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 8, weight: .bold))
            Text(ref.name).lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(ref.isHead ? 0.8 : 0), lineWidth: 1))
        .fixedSize()
    }
}

/// One row of the commit graph: the lanes passing through, joining and leaving, and the
/// commit's dot. In `.through` mode (under an expanded commit) the lanes just carry on.
private struct GraphLines: View {
    enum Mode {
        case commit(isHead: Bool, isMerge: Bool)
        case through
    }

    let row: CommitGraph.Row
    let theme: TerminalTheme?
    let mode: Mode
    private static let lane: CGFloat = 12

    static func color(_ lane: Int, theme: TerminalTheme?) -> Color {
        let order = [4, 5, 6, 2, 3, 1]
        let fallback: [Color] = [.blue, .purple, .cyan, .green, .yellow, .red]
        guard let ansi = theme?.ansi else { return fallback[lane % fallback.count] }
        return Color(uiColor: UIColor(hex: ansi[order[lane % order.count]]))
    }

    var body: some View {
        Canvas { context, size in
            func x(_ lane: Int) -> CGFloat { 6 + CGFloat(lane) * Self.lane }
            let middle = size.height / 2
            func y(_ point: CommitGraph.Segment.Point) -> CGFloat {
                switch point {
                case .top: 0
                case .middle: middle
                case .bottom: size.height
                }
            }
            let style = StrokeStyle(lineWidth: 2, lineCap: .round)
            switch mode {
            case .through:
                for lane in row.continuing {
                    var path = Path()
                    path.move(to: CGPoint(x: x(lane), y: 0))
                    path.addLine(to: CGPoint(x: x(lane), y: size.height))
                    context.stroke(path, with: .color(Self.color(lane, theme: theme)), style: style)
                }
            case .commit(let isHead, let isMerge):
                for segment in row.segments {
                    let start = CGPoint(x: x(segment.fromLane), y: y(segment.from))
                    let end = CGPoint(x: x(segment.toLane), y: y(segment.to))
                    var path = Path()
                    path.move(to: start)
                    if start.x == end.x {
                        path.addLine(to: end)
                    } else {
                        let bend = (start.y + end.y) / 2
                        path.addCurve(to: end, control1: CGPoint(x: start.x, y: bend), control2: CGPoint(x: end.x, y: bend))
                    }
                    context.stroke(path, with: .color(Self.color(segment.colorLane, theme: theme)), style: style)
                }
                let color = Self.color(row.lane, theme: theme)
                let radius: CGFloat = isHead ? 5 : 4
                let dot = Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: middle - radius, width: radius * 2, height: radius * 2))
                if isMerge || isHead {
                    context.fill(dot, with: .color(Color(uiColor: theme?.editorChrome(0.05) ?? .systemBackground)))
                    context.stroke(dot, with: .color(color), lineWidth: 2)
                } else {
                    context.fill(dot, with: .color(color))
                }
            }
        }
    }
}

// MARK: - Rows

struct TreeRow: View {
    let row: ExplorerModel.Row
    let isExpanded: Bool
    let badge: Character?
    var isOpen = false
    /// Underlined with a red squiggle, as the error is in the code.
    var hasErrors = false
    @Environment(\.editorTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if row.entry.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
            } else {
                Spacer().frame(width: 12)
                FileIcon(name: row.entry.name)
            }
            Text(row.entry.name)
                .lineLimit(1)
                .italic(row.entry.isSymlink)
                .fontWeight(isOpen ? .semibold : .regular)
                .foregroundStyle(badge.map { GitBadge.color(for: $0, theme: theme) } ?? .primary)
                .overlay(alignment: .bottom) {
                    if hasErrors {
                        Squiggle()
                            .stroke(theme.map { Color(uiColor: $0.problemColor(.error)) } ?? .red, lineWidth: 1)
                            .frame(height: 3)
                            .offset(y: 3)
                    }
                }
            Spacer(minLength: 4)
            if let badge { GitBadge(letter: badge) }
        }
        // VoiceOver: "Program.cs, modified, has errors" (the squiggle and letter are visual).
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasErrors ? "has errors" : "")
        .font(.callout)
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
    }
}

/// A zigzag across its frame, like the code view's error underline.
struct Squiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 2
        var x = rect.minX
        path.move(to: CGPoint(x: x, y: rect.maxY))
        var up = true
        while x < rect.maxX {
            x = min(x + step, rect.maxX)
            path.addLine(to: CGPoint(x: x, y: up ? rect.minY : rect.maxY))
            up.toggle()
        }
        return path
    }
}

struct GitBadge: View {
    let letter: Character
    @Environment(\.editorTheme) private var theme

    var body: some View {
        Text(String(letter))
            .font(.caption.monospaced().weight(.bold))
            .foregroundStyle(Self.color(for: letter, theme: theme))
            .accessibilityLabel(Self.spoken(letter))
    }

    /// What VoiceOver says for git's letter.
    static func spoken(_ letter: Character) -> String {
        switch letter {
        case "U": "untracked"
        case "A": "added"
        case "M": "modified"
        case "D": "deleted"
        case "R": "renamed"
        case "C": "conflict"
        case "•": "contains changes"
        default: String(letter)
        }
    }

    /// The theme's own green/red/yellow, which it makes readable on its background.
    static func color(for letter: Character, theme: TerminalTheme?) -> Color {
        let ansi = theme?.ansi
        switch letter {
        case "A", "U": return ansi.map { Color(uiColor: UIColor(hex: $0[2])) } ?? .green
        case "D", "C": return ansi.map { Color(uiColor: UIColor(hex: $0[1])) } ?? .red
        case "•": return (ansi.map { Color(uiColor: UIColor(hex: $0[3])) } ?? .orange).opacity(0.8)
        default: return ansi.map { Color(uiColor: UIColor(hex: $0[3])) } ?? .orange
        }
    }
}

private struct EditorThemeKey: EnvironmentKey {
    static let defaultValue: TerminalTheme? = nil
}

extension EnvironmentValues {
    /// The theme the editor is drawn in, for views that colour themselves from it.
    var editorTheme: TerminalTheme? {
        get { self[EditorThemeKey.self] }
        set { self[EditorThemeKey.self] = newValue }
    }
}
