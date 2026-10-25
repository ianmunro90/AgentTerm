import SwiftUI

@main
struct AgentTermApp: App {
    @StateObject private var hosts = HostStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var windows = WindowRegistry()
    @StateObject private var snippets = SnippetStore()
    @StateObject private var lock = AppLock()

    init() {
        // Hosts and trusted keys now live in the App Group, shared with the Share extension.
        SharedStore.migrateFromStandardDefaults()
        EventLog.record("app launch")
        #if DEBUG
        // Lets a simulator run be authorized on a test host: `simctl launch --console-pty … -printPublicKey`.
        if CommandLine.arguments.contains("-printPublicKey"), let key = try? KeyManager.loadOrCreate() {
            print(KeyManager.openSSHPublicKey(for: key))
            fflush(stdout)
        }
        if CommandLine.arguments.contains("-selfTestDelete") {
            AgentTerminalView.selfTestDelete()
        }
        if CommandLine.arguments.contains("-selfTestViewer") {
            DispatchQueue.main.async { ViewerSelfTest.run() }
        }
        Self.selfTestKeyParsing()
        Self.dumpServerScripts()
        if CommandLine.arguments.contains("-selfTestUpload") {
            Task { await Self.selfTestUpload() }
        }
        if CommandLine.arguments.contains("-selfTestGestures") {
            DispatchQueue.main.async { AgentTerminalView.selfTestGestures() }
        }
        if CommandLine.arguments.contains("-selfTestCopy") {
            DispatchQueue.main.async { TerminalSession.selfTestCopy() }
        }
        if CommandLine.arguments.contains("-selfTestMouse") {
            DispatchQueue.main.async { TerminalSession.selfTestMouse() }
        }
        #endif
    }

    #if DEBUG
    /// -dumpServerScripts <folder>: writes the probe script and, for each package manager, the
    /// script installing everything on a bare system (no curl, bash, Node), for container tests.
    static func dumpServerScripts() {
        guard let index = CommandLine.arguments.firstIndex(of: "-dumpServerScripts"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try? ServerCheck.probeScript.write(to: folder.appendingPathComponent("probe.sh"), atomically: true, encoding: .utf8)
        for manager in ["apt-get", "dnf", "yum", "pacman", "zypper", "apk", "brew"] {
            var report = ServerCheck.Report()
            report.packageManager = manager
            report.hasSudo = true
            let script = ServerCheck.installScript(Set(ServerCheck.Tool.allCases), report: report)
            try? script.write(to: folder.appendingPathComponent("install-\(manager).sh"), atomically: true, encoding: .utf8)
        }
        EventLog.record("dumped server scripts to \(folder.path)")
    }

    /// -keyParseTest <folder>: parses each key file there (passphrase "test-pass" and a wrong
    /// one), logging the result, without storing anything.
    static func selfTestKeyParsing() {
        guard let index = CommandLine.arguments.firstIndex(of: "-keyParseTest"), CommandLine.arguments.indices.contains(index + 1) else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? [] where !name.hasSuffix(".pub") {
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            for passphrase in ["", "test-pass", "wrong"] {
                do {
                    let key = try KeyManager.parseOpenSSH(text, passphrase: passphrase)
                    EventLog.record("keytest \(name) pass=\(passphrase.isEmpty ? "-" : passphrase): OK \(KeyManager.openSSHPublicKey(for: key).prefix(60))")
                } catch {
                    EventLog.record("keytest \(name) pass=\(passphrase.isEmpty ? "-" : passphrase): \(error.localizedDescription.prefix(70))")
                }
            }
        }
    }

    /// Uploads a file with a space in its name and the same image twice to the first host.
    static func selfTestUpload() async {
        let directory = FileManager.default.temporaryDirectory
        let text = directory.appendingPathComponent("selftest text")
        let image = directory.appendingPathComponent("selftest image")
        try? Data("hello from AgentTerm ✓\n".utf8).write(to: text)
        try? Data(repeating: 0xAB, count: 600_000).write(to: image)
        let items = [
            Uploader.Item(localURL: text, filename: "agentterm selftest.txt"),
            Uploader.Item(localURL: image, filename: "agentterm-selftest.png"),
            Uploader.Item(localURL: image, filename: "agentterm-selftest.png"),
        ]
        do {
            guard let host = HostStore().hosts.first else { return EventLog.record("selftest upload: no host") }
            let paths = try await Uploader.upload(items, to: host)
            EventLog.record("selftest upload paths=\(paths) typed=\(Uploader.shellQuoted(paths))")
        } catch {
            EventLog.record("selftest upload failed: \(error)")
        }
    }
    #endif

    var body: some Scene {
        // Every window (iPad Split View, Stage Manager, "Open in New Window") gets its own sessions.
        WindowGroup(id: "terminal", for: HostProfile.ID.self) { $requestedHost in
            WindowRoot(requestedHost: requestedHost)
                .environmentObject(hosts)
                .environmentObject(settings)
                .environmentObject(windows)
                .environmentObject(snippets)
                .environmentObject(lock)
        }
        .commands {
            TerminalCommands(settings: settings)
        }
    }
}

/// The Terminal menu (iPadOS menu bar and the ⌘-hold shortcut list) for the focused window.
private struct TerminalCommands: Commands {
    let settings: AppSettings
    @FocusedValue(\.activeTerminal) private var session

    var body: some Commands {
        CommandMenu("Terminal") {
            Button("Reconnect") { session?.reconnect() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.isActive != true)
            Divider()
            // tmux windows, like browser tabs.
            Button("Next Window") { tmuxWindow(.nextWindow) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.isActive != true)
            Button("Previous Window") { tmuxWindow(.previousWindow) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.isActive != true)
            Divider()
            Button("Larger Text") { settings.fontSize = min(28, settings.fontSize + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Smaller Text") { settings.fontSize = max(9, settings.fontSize - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Text Size") { settings.fontSize = 14 }
                .keyboardShortcut("0", modifiers: .command)
        }
    }

    private func tmuxWindow(_ action: TmuxService.PaneAction) {
        guard let session else { return }
        Task { _ = try? await TmuxService.perform(action, on: session.host, tag: session.tag) }
    }
}

struct ActiveTerminalKey: FocusedValueKey {
    typealias Value = TerminalSession
}

extension FocusedValues {
    /// The session shown in the focused window, for menu commands.
    var activeTerminal: TerminalSession? {
        get { self[ActiveTerminalKey.self] }
        set { self[ActiveTerminalKey.self] = newValue }
    }
}

/// Owns one window's sessions and its window number.
private struct WindowRoot: View {
    let requestedHost: HostProfile.ID?
    @StateObject private var sessions = SessionManager()
    @EnvironmentObject private var windows: WindowRegistry
    @SceneStorage("windowSlot") private var storedSlot = 0
    @State private var slot = 0
    @State private var scene: UIWindowScene?

    var body: some View {
        Group {
            if slot > 0 {
                RootView(requestedHost: requestedHost, windowSlot: slot)
                    .environmentObject(sessions)
            } else {
                Color.clear
            }
        }
        .background(WindowSceneReader { resolved in
            if scene !== resolved { EventLog.record("window slot=\(slot) scene=\(ObjectIdentifier(resolved).hashValue)") }
            scene = resolved
        })
        .onAppear {
            EventLog.record("window appear slot=\(slot) stored=\(storedSlot)")
            guard slot == 0 else { return }
            slot = windows.claim(preferred: storedSlot)
            storedSlot = slot
            sessions.windowSlot = slot
            EventLog.record("window claimed slot=\(slot)")
        }
        .onDisappear {
            EventLog.record("window disappear slot=\(slot) (sessions kept)")
        }
        // Not onDisappear: that also fires when another window covers this one, and closing
        // there dropped live sessions. A disconnected scene is really gone.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
            let other = (note.object as? UIScene).map { ObjectIdentifier($0).hashValue } ?? 0
            guard let scene, note.object as? UIWindowScene === scene else {
                EventLog.record("scene disconnect (not ours) slot=\(slot) scene=\(other) ours=\(scene.map { ObjectIdentifier($0).hashValue } ?? 0)")
                return
            }
            EventLog.record("scene disconnect ours slot=\(slot) -> closeAll")
            sessions.closeAll()
            windows.release(slot)
        }
    }
}

/// Reports the UIWindowScene hosting this view.
private struct WindowSceneReader: UIViewRepresentable {
    let onResolve: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var onResolve: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            // Deferred: this runs inside a SwiftUI update.
            DispatchQueue.main.async { [onResolve] in onResolve?(scene) }
        }
    }
}
