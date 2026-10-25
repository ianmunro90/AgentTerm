import SwiftUI

struct RootView: View {
    let requestedHost: HostProfile.ID?
    let windowSlot: Int
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var sessions: SessionManager
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    @State private var selection: HostProfile.ID?
    /// Created in `.task`, never in `body`: building a TerminalView (and its keyboard accessory)
    /// during a SwiftUI update re-enters the view graph and hangs the first scene on device.
    @State private var activeSession: TerminalSession?
    @State private var editing: HostProfile?
    @State private var showingSetup = false
    /// The host whose tools are being checked (Check Server…).
    @State private var checking: HostProfile?
    @State private var showingKey = false
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// On iPhone (one column at a time): the host list, or the terminal/editor.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// Terminal or editor, per window.
    @State private var mode = WindowMode.terminal
    @State private var workspace: EditorWorkspace?

    enum WindowMode { case terminal, editor }
    @StateObject private var tmux = TmuxSidebarModel()
    @State private var killing: (host: HostProfile, session: TmuxSession)?
    /// A tmux window being renamed or closed from the sidebar.
    @State private var renamingWindow: (host: HostProfile, session: String, window: TmuxWindow)?
    @State private var closingWindow: (host: HostProfile, session: String, window: TmuxWindow)?
    @State private var windowName = ""
    @State private var creatingFor: HostProfile?
    @State private var newSessionName = ""

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            if mode == .editor, let workspace {
                EditorSidebar(workspace: workspace, onTerminal: showTerminal,
                              onKey: { showingKey = true }, onSettings: { showingSettings = true })
                    // A dense side bar: text grows to the largest standard size, not the
                    // accessibility ones, where its rows of icons and labels would overlap.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else {
                hostList
            }
        } detail: {
            if mode == .editor, let workspace {
                EditorArea(workspace: workspace, onTerminal: showTerminal)
            } else {
                terminalDetail
            }
        }
        // The whole window (status bar, sheets) follows the theme's light or dark.
        .preferredColorScheme(sidebarTheme.isLight ? .light : .dark)
        .sheet(item: $editing, onDismiss: refocusTerminal) { host in
            HostEditorView(host: host)
        }
        .sheet(isPresented: $showingSetup, onDismiss: refocusTerminal) {
            SetupGuide { host in
                selection = host.id
                compactColumn = .detail
            }
        }
        .sheet(item: $checking, onDismiss: refocusTerminal) { host in
            NavigationStack {
                ServerCheckView(host: host)
                    .navigationTitle("Check \(host.name.isEmpty ? host.hostname : host.name)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { checking = nil }
                        }
                    }
            }
            .pageSizedSheet()
        }
        .sheet(isPresented: $showingKey, onDismiss: refocusTerminal) {
            KeyView()
        }
        .sheet(isPresented: $showingSettings, onDismiss: refocusTerminal) {
            SettingsView()
        }
        .confirmationDialog(
            "Kill tmux session “\(killing?.session.name ?? "")”?",
            isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Kill Session", role: .destructive) {
                guard let target = killing else { return }
                Task {
                    do {
                        try await TmuxService.kill(on: target.host, session: target.session.name)
                    } catch {
                        tmux.errors[target.host.id] = error.localizedDescription
                    }
                    await refreshTmux()
                }
            }
        } message: {
            Text("Everything running in it (shells, Claude Code, …) is terminated. Windows showing it switch to another session.")
        }
        .alert("Rename Window", isPresented: Binding(get: { renamingWindow != nil }, set: { if !$0 { renamingWindow = nil } })) {
            TextField("Name", text: $windowName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                guard let target = renamingWindow else { return }
                let name = windowName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                Task {
                    try? await TmuxService.renameWindow(on: target.host, session: target.session, index: target.window.index, to: name)
                    await refreshTmux()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Close window “\(closingWindow.map { "\($0.window.index): \($0.window.name)" } ?? "")”?",
            isPresented: Binding(get: { closingWindow != nil }, set: { if !$0 { closingWindow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close Window", role: .destructive) {
                guard let target = closingWindow else { return }
                Task {
                    try? await TmuxService.closeWindow(on: target.host, session: target.session, index: target.window.index)
                    await refreshTmux()
                }
            }
        } message: {
            Text("Ends everything running in its panes.")
        }
        .alert("New tmux Session", isPresented: Binding(get: { creatingFor != nil }, set: { if !$0 { creatingFor = nil } })) {
            TextField("Name", text: $newSessionName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Create") {
                guard let host = creatingFor else { return }
                let name = TmuxService.sanitizedName(newSessionName)
                guard !name.isEmpty else { return }
                createSession(name, on: host)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Opens in this window. Your current session keeps running.")
        }
        // Poll tmux only while the sidebar is showing.
        .task(id: columnVisibility != .detailOnly) {
            guard columnVisibility != .detailOnly else { return }
            while !Task.isCancelled {
                await refreshTmux()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onAppear {
            if selection == nil { selection = requestedHost ?? hosts.hosts.first?.id }
            // iPhone: straight to the terminal, as iPad shows it beside the list.
            if selection != nil { compactColumn = .detail }
            #if DEBUG
            if CommandLine.arguments.contains("-showHosts") { compactColumn = .sidebar }
            #endif
            // A first launch: the setup guide.
            if hosts.hosts.isEmpty { showingSetup = true }
            #if DEBUG
            if CommandLine.arguments.contains("-editHost") { editing = hosts.hosts.first }
            if CommandLine.arguments.contains("-checkServer") { checking = hosts.hosts.first }
            if CommandLine.arguments.contains("-showAbout") { showingSettings = true }
            if CommandLine.arguments.contains("-openEditor") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if let session = activeSession { showEditor(for: session) }
                }
            }
            #endif
        }
        .task(id: selection) {
            guard let id = selection, let host = hosts.hosts.first(where: { $0.id == id }) else {
                activeSession = nil
                return
            }
            activeSession = sessions.session(for: host, settings: settings)
        }
        .onChange(of: hosts.hosts) { _, updated in
            sessions.apply(settings, hosts: updated)
        }
        .onChange(of: settings.fontSize) {
            sessions.apply(settings, hosts: hosts.hosts)
        }
        .onChange(of: settings.defaultThemeID) {
            sessions.apply(settings, hosts: hosts.hosts)
        }
        .onChange(of: scenePhase) { _, phase in
            EventLog.record("scenePhase slot=\(windowSlot) \(phase)")
            if phase == .active { Task { await refreshTmux() } }
            switch phase {
            case .background:
                sessions.didEnterBackground()
                workspace?.setWatching(false)
            case .active:
                sessions.didBecomeActive()
                if mode == .editor, let workspace {
                    Task {
                        await workspace.explorer.refresh()
                        workspace.setWatching(true)
                    }
                }
            default: break
            }
        }
    }

    private var hostList: some View {
            List {
                ForEach(hosts.hosts) { host in
                    Button {
                        selection = host.id
                        compactColumn = .detail
                        // Tapping a host whose connection has dropped reconnects it.
                        if let session = sessions.existingSession(for: host.id), case .closed = session.state {
                            session.connect()
                        }
                    } label: {
                        HostRow(host: host, session: sessions.existingSession(for: host.id))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(SidebarHighlight(isOn: selection == host.id && activeTmux(for: host) == nil))
                        .contextMenu {
                            if UIApplication.shared.supportsMultipleScenes {
                                Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                                    openWindow(id: "terminal", value: host.id)
                                }
                            }
                            Button("Edit", systemImage: "pencil") { editing = host }
                            Button("Check Server…", systemImage: "checklist") { checking = host }
                            if let session = sessions.existingSession(for: host.id) {
                                Button("Reconnect", systemImage: "arrow.clockwise") {
                                    selection = host.id
                                    session.reconnect()
                                }
                                if session.isActive {
                                    Button("Disconnect", systemImage: "bolt.horizontal.circle") { session.disconnect() }
                                }
                                Button("Close Session", systemImage: "xmark.circle") { sessions.close(host.id) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                if selection == host.id { selection = nil }
                                sessions.close(host.id)
                                hosts.delete(host)
                                Passwords.forget(host)
                            }
                        }
                    ForEach(tmux.sessions[host.id] ?? []) { tmuxSession in
                        Button {
                            attach(host, to: tmuxSession.name)
                        } label: {
                            TmuxSessionRow(session: tmuxSession)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(SidebarHighlight(isOn: tmuxSession.isThisWindow))
                        .contextMenu {
                            Button("Attach in This Window", systemImage: "arrow.right.circle") {
                                attach(host, to: tmuxSession.name)
                            }
                            // Never the host's only session (that would end tmux there).
                            if (tmux.sessions[host.id]?.count ?? 0) > 1 {
                                Button("Kill Session…", systemImage: "xmark.octagon", role: .destructive) {
                                    killing = (host, tmuxSession)
                                }
                            }
                        }
                        // Its windows, when there's more than one: tap to show one here.
                        if tmuxSession.windowList.count > 1 {
                            ForEach(tmuxSession.windowList) { window in
                                Button {
                                    showWindow(window, of: tmuxSession.name, on: host)
                                } label: {
                                    TmuxWindowRow(window: window, isThisWindow: tmuxSession.isThisWindow)
                                }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                // Clear like the others (iPhone's grouped list would card it).
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Rename Window…", systemImage: "pencil") {
                                        windowName = window.name
                                        renamingWindow = (host, tmuxSession.name, window)
                                    }
                                    Button("Close Window…", systemImage: "xmark.square", role: .destructive) {
                                        closingWindow = (host, tmuxSession.name, window)
                                    }
                                }
                            }
                        }
                    }
                    if tmux.sessions[host.id] != nil {
                        Button {
                            newSessionName = suggestedSessionName(for: host)
                            creatingFor = host
                        } label: {
                            Label("New Session", systemImage: "plus.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 18)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .refreshable { await refreshTmux() }
            // Lets tmux window rows sit compactly under their session (hosts and sessions are
            // taller anyway).
            .environment(\.defaultMinListRowHeight, 30)
            // A safe-area inset rather than a bottom toolbar, so it rides up with the keyboard.
            // Styled like the toolbar it replaced: plain primary-coloured glyphs in the corners.
            .safeAreaInset(edge: .bottom) {
                SidebarFooter(onKey: { showingKey = true }, onSettings: { showingSettings = true },
                              background: Color(uiColor: sidebarTheme.editorChrome(0.05)))
            }
            // Same look as the terminal beside it and the editor's side bar.
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: sidebarTheme.editorChrome(0.05)))
            .environment(\.colorScheme, sidebarTheme.isLight ? .light : .dark)
            .toolbarColorScheme(sidebarTheme.isLight ? .light : .dark, for: .navigationBar)
            .navigationTitle(windowSlot > 1 ? "AgentTerm · \(windowSlot)" : "AgentTerm")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") {
                        showingSetup = true
                    }
                }
            }
    }

    /// The selected host's theme (or the default), so the sidebar matches its terminal.
    private var sidebarTheme: TerminalTheme {
        hosts.hosts.first { $0.id == selection }.map(settings.theme(for:)) ?? TerminalTheme.named(settings.defaultThemeID)
    }

    @ViewBuilder
    private var terminalDetail: some View {
            if let session = activeSession, session.host.id == selection {
                TerminalScreen(session: session, onOpenEditor: { showEditor(for: session) },
                               inTmux: activeTmux(for: session.host) != nil, onConnected: {
                    hideSidebarIfEnabled()
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        await refreshTmux()
                    }
                })
                .id(session.host.id)
            } else if selection != nil {
                ProgressView()
            } else if hosts.hosts.isEmpty {
                ContentUnavailableView {
                    Label("Add a Server", systemImage: "server.rack")
                } description: {
                    Text("Connect to a computer over SSH: its address, your username, and a password or this device's key.")
                } actions: {
                    Button("Add Server") { showingSetup = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("No Host Selected", systemImage: "terminal", description: Text("Pick a host from the sidebar."))
            }
    }

    /// After a sheet closes: the terminal takes the keyboard back (it doesn't while covered).
    private func refocusTerminal() {
        guard mode == .terminal, let session = activeSession else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.terminalView.focusUnlessCovered() }
    }

    // MARK: Editor mode

    private func showEditor(for session: TerminalSession) {
        let workspace = sessions.workspace(for: session)
        workspace.onHandToClaude = { showTerminal() }
        workspace.onShowSidebar = {
            withAnimation { columnVisibility = .all }
            compactColumn = .sidebar
        }
        workspace.onShowTab = { compactColumn = .detail }
        self.workspace = workspace
        withAnimation {
            mode = .editor
            columnVisibility = .all
        }
        // iPhone: the open file, or the Explorer to pick one.
        compactColumn = workspace.tabs.isEmpty ? .sidebar : .detail
        Task {
            await workspace.didEnterEditor()
            workspace.setWatching(true)
            #if DEBUG
            await EditorDebug.run(workspace: workspace, settings: settings)
            #endif
        }
    }

    private func showTerminal() {
        workspace?.setWatching(false)
        withAnimation { mode = .terminal }
        compactColumn = .detail
    }

    private func refreshTmux() async {
        await tmux.refresh(hosts.hosts, windowSlot: windowSlot)
    }

    private func hideSidebarIfEnabled() {
        guard settings.autoHideSidebar, columnVisibility != .detailOnly else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-showHosts") { return }
        #endif
        withAnimation { columnVisibility = .detailOnly }
    }

    private func activeTmux(for host: HostProfile) -> TmuxSession? {
        tmux.sessions[host.id]?.first(where: \.isThisWindow)
    }

    private func suggestedSessionName(for host: HostProfile) -> String {
        let existing = Set((tmux.sessions[host.id] ?? []).map(\.name))
        guard existing.contains("main") else { return "main" }
        var n = 2
        while existing.contains("main-\(n)") { n += 1 }
        return "main-\(n)"
    }

    private func createSession(_ name: String, on host: HostProfile) {
        if tmux.sessions[host.id]?.contains(where: { $0.name == name }) == true {
            attach(host, to: name)
            return
        }
        Task {
            // A connected window just switches; otherwise attach() connects with `tmux new -A`,
            // which creates the session itself.
            if sessions.existingSession(for: host.id)?.state == .connected {
                do {
                    try await TmuxService.create(on: host, session: name)
                } catch {
                    tmux.errors[host.id] = error.localizedDescription
                    return
                }
            }
            attach(host, to: name)
        }
    }

    /// Shows one of a session's windows here: makes it the session's current window, then
    /// shows the session (switching or reconnecting as needed).
    private func showWindow(_ window: TmuxWindow, of session: String, on host: HostProfile) {
        Task {
            try? await TmuxService.selectWindow(on: host, session: session, index: window.index)
            attach(host, to: session)
        }
    }

    /// Shows the tmux session `name` in this window: switch the existing tmux client if there is
    /// one, otherwise (re)connect straight into it.
    private func attach(_ host: HostProfile, to name: String) {
        selection = host.id
        compactColumn = .detail
        tmux.markActive(name, on: host.id)
        Task {
            let session = sessions.session(for: host, settings: settings)
            session.tmuxTarget = name
            var switched = false
            if session.state == .connected {
                switched = (try? await TmuxService.switchClient(on: host, tag: session.tag, to: name)) ?? false
            }
            if !switched { session.reconnect() }
            hideSidebarIfEnabled()
            try? await Task.sleep(for: .seconds(1))
            await refreshTmux()
        }
    }
}

/// tmux sessions per host for one window's sidebar.
@MainActor
final class TmuxSidebarModel: ObservableObject {
    @Published var sessions: [HostProfile.ID: [TmuxSession]] = [:]
    @Published var errors: [HostProfile.ID: String] = [:]
    private var refreshing = false

    /// Highlights `name` straight away; the next refresh confirms it.
    func markActive(_ name: String, on host: HostProfile.ID) {
        guard var list = sessions[host] else { return }
        for index in list.indices { list[index].isThisWindow = list[index].name == name }
        sessions[host] = list
    }

    func refresh(_ hosts: [HostProfile], windowSlot: Int) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for host in hosts {
            do {
                let list = try await TmuxService.list(on: host, tag: TerminalSession.tag(host: host, slot: windowSlot))
                if sessions[host.id] != list { sessions[host.id] = list }
                errors[host.id] = nil
            } catch {
                // Unreachable or untrusted hosts just show no sessions.
                if sessions[host.id] != nil { sessions[host.id] = nil }
            }
        }
    }
}

/// A 44 pt borderless glyph that dims while pressed, like a toolbar button.
/// The sidebar's bottom corners: this device's key and Settings, as plain glyphs. Used as a
/// bottom safe-area inset (not a toolbar) so it rides up with the keyboard.
struct SidebarFooter: View {
    let onKey: () -> Void
    let onSettings: () -> Void
    /// The sidebar's colour: the bar is opaque, so rows scroll under it rather than show
    /// through behind the glyphs.
    let background: Color

    var body: some View {
        HStack {
            Button("This Device's Key", systemImage: "key", action: onKey)
            Spacer()
            Button("Settings", systemImage: "gearshape", action: onSettings)
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 21))
        .foregroundStyle(.primary)
        .buttonStyle(SidebarGlyphButtonStyle())
        .padding(.horizontal, 4)
        .background(background.ignoresSafeArea(edges: .bottom))
    }
}

private struct SidebarGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.4 : 1)
    }
}

/// The tinted rounded background for the row this window is showing.
private struct SidebarHighlight: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? AnyShapeStyle(.tint.opacity(0.22)) : AnyShapeStyle(.clear))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
    }
}

private struct TmuxSessionRow: View {
    let session: TmuxSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.isThisWindow ? "rectangle.inset.filled.and.person.filled" : "rectangle.stack")
                .foregroundStyle(session.isThisWindow ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.callout.monospaced())
                    .fontWeight(session.isThisWindow ? .semibold : .regular)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .contentShape(Rectangle())
    }

    private var detail: String {
        let windows = "\(session.windows) \(session.windows == 1 ? "window" : "windows")"
        let status = session.isThisWindow ? "this window" : session.attachedClients > 0 ? "attached" : "detached"
        let age = session.lastActivity.formatted(.relative(presentation: .named))
        return "\(windows) · \(status) · active \(age)"
    }
}

private struct TmuxWindowRow: View {
    let window: TmuxWindow
    /// Its session is the one this window shows.
    let isThisWindow: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: window.panes > 1 ? "rectangle.split.2x1" : "macwindow")
                .font(.caption)
                .foregroundStyle(window.isActive && isThisWindow ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            Text("\(window.index): \(window.name)")
                .font(.caption.monospaced())
                .fontWeight(window.isActive && isThisWindow ? .semibold : .regular)
                .lineLimit(1)
            if window.isActive {
                Circle().fill(isThisWindow ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 5, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 48)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
    }
}

private struct HostRow: View {
    /// The host name as shown (DEBUG: -displayHostname <name> stands in, for screenshots).
    static func shown(_ hostname: String) -> String {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "-displayHostname"), CommandLine.arguments.indices.contains(index + 1) {
            return CommandLine.arguments[index + 1]
        }
        #endif
        return hostname
    }

    let host: HostProfile
    let session: TerminalSession?

    var body: some View {
        HStack(spacing: 10) {
            if let session {
                SessionStatusDot(session: session)
            } else {
                StatusDot(color: .secondary.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name.isEmpty ? host.hostname : host.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text("\(host.username)@\(HostRow.shown(host.hostname))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if host.useMosh {
                        Text("mosh")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.2), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SessionStatusDot: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        StatusDot(color: session.state.color)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

extension TerminalSession.State {
    var color: Color {
        switch self {
        case .idle: .secondary.opacity(0.4)
        case .connecting: .orange
        case .connected: .green
        case .closed(let message): message == nil ? .secondary : .red
        }
    }

}
