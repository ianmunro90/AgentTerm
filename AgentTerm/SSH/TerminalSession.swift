import Citadel
import Foundation
import NIOCore
import NIOSSH
import SwiftTerm
import UIKit

/// One shell bound to one SwiftTerm view, over SSH or mosh. The view outlives connections so
/// scrollback survives a reconnect (tmux redraws the screen anyway).
@MainActor
final class TerminalSession: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case closed(String?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var title = ""
    /// Transient connection warning, e.g. mosh hasn't heard from the server for a while.
    @Published private(set) var notice: String?
    /// The editor handing a request to Claude Code ("Starting Claude Code…"), for the banner.
    @Published private(set) var handoff: String?
    private var handoffClear: Task<Void, Never>?
    @Published var hostKeyChallenge: HostKeyChallenge?
    /// The password prompt while logging in.
    @Published var passwordRequest: PasswordRequest?
    /// Logged in with a password: offer to add this device's key to the host, so it isn't
    /// needed again.
    @Published var offeringKeyInstall = false
    /// Whether the password typed at the prompt is to be saved in the Keychain.
    private var savePromptedPassword = false
    /// When the remote side last put text on the iPad clipboard (OSC 52, e.g. a tmux selection).
    @Published private(set) var lastCopy: Date?

    private(set) var host: HostProfile
    let windowSlot: Int
    let terminalView: TerminalView

    private var client: SSHClient?
    private var runTask: Task<Void, Never>?
    /// SSH: keystrokes and resizes go through one queue so they reach the server in order.
    private var input: AsyncStream<Input>.Continuation?
    private var mosh: MoshClient?
    private var moshRenderer = MoshRenderer()
    /// A mouse press waiting to be classified as a tap or the start of a drag.
    fileprivate var pendingPress: MouseAssist.Report?
    #if DEBUG
    /// Self-tests capture outgoing bytes here instead of sending them.
    var debugDelivered: (([UInt8]) -> Void)?
    #endif
    private var backgroundedAt: Date?

    /// A detached mosh-server exits after this long without hearing from the app (iPadOS may
    /// kill the app without warning, so the server can't rely on a clean shutdown).
    private static let moshServerTimeout = 86400

    /// Identifies this app install in mosh-server and tmux-client tags.
    private static let installID: String = {
        if let id = UserDefaults.standard.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installID")
        return id
    }()

    private enum Input {
        case bytes([UInt8])
        case resize(cols: Int, rows: Int)
    }

    init(host: HostProfile, windowSlot: Int, fontSize: CGFloat, theme: TerminalTheme) {
        self.host = host
        self.windowSlot = windowSlot
        terminalView = AgentTerminalView.make(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.terminalDelegate = self
        apply(theme: theme)
        setFontSize(fontSize)
        EventLog.record("session init host=\(host.name) slot=\(windowSlot) \(ObjectIdentifier(self).hashValue) hasText=\((terminalView as UIKeyInput).hasText)")
    }

    deinit {
        EventLog.record("session deinit \(ObjectIdentifier(self).hashValue)")
    }

    var isActive: Bool { state == .connecting || state == .connected }

    /// Identifies this window's shell on the host: install + host + window number.
    var tag: String { Self.tag(host: host, slot: windowSlot) }

    static func tag(host: HostProfile, slot: Int) -> String {
        "\(installID)-\(host.id.uuidString)-\(slot)"
    }

    /// Set when the user picks a tmux session in the sidebar; later (re)connects attach to it
    /// instead of running the host's startup command.
    var tmuxTarget: String?

    private var startupCommand: String {
        tmuxTarget.map(TmuxService.attachCommand) ?? host.startupCommand(window: windowSlot)
    }

    func update(host: HostProfile) {
        self.host = host
    }

    func setFontSize(_ size: CGFloat) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func apply(theme: TerminalTheme) {
        theme.apply(to: terminalView)
        terminalView.setNeedsDisplay()
    }

    func connect() {
        guard !isActive else { return }
        runTask = Task { await run() }
    }

    func disconnect() {
        EventLog.record("session disconnect slot=\(windowSlot) mosh=\(mosh != nil) state=\(state)")
        hostKeyChallenge?.respond(false)
        passwordRequest?.respond(nil, false)
        runTask?.cancel()
        input?.finish()
        let client = self.client
        Task { try? await client?.close() }
        if mosh != nil {
            finish(nil)
        }
    }

    func reconnect() {
        guard !isActive else {
            disconnect()
            Task {
                await runTask?.value
                connect()
            }
            return
        }
        connect()
    }

    /// Shows `message` in the banner (nil hides it), for `seconds` if given.
    func setHandoff(_ message: String?, for seconds: Double? = nil) {
        handoffClear?.cancel()
        handoff = message
        guard let seconds else { return }
        handoffClear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.handoff = nil
        }
    }

    /// Delivers `text` as a paste: one bracketed paste when the program has asked for those, so
    /// e.g. Claude Code turns a pasted image path into an attachment ([Image #1]).
    func paste(_ text: String) {
        guard terminalView.getTerminal().bracketedPasteMode else {
            sendInput(text, pressReturn: false)
            return
        }
        deliver(Array("\u{1b}[200~".utf8) + Array(text.utf8) + Array("\u{1b}[201~".utf8))
    }

    /// Types `text` into the session, as a single bracketed paste when it spans several lines
    /// and the program has asked for that, then optionally presses Return.
    func sendInput(_ text: String, pressReturn: Bool) {
        // Plain one-line text goes through the keyboard path so it lands in SwiftTerm's input
        // buffer like typed text: iOS only repeats a held backspace over text it can see there.
        if !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) {
            terminalView.insertText(text)
            if pressReturn { terminalView.insertText("\n") }
            return
        }
        var bytes = Array(text.utf8)
        if text.contains("\n"), terminalView.getTerminal().bracketedPasteMode {
            bytes = Array("\u{1b}[200~".utf8) + bytes + Array("\u{1b}[201~".utf8)
        }
        if pressReturn { bytes.append(13) }
        deliver(bytes)
    }

    // MARK: Foreground / background

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    /// iOS suspends the app shortly after it leaves the screen. SSH's TCP connection doesn't
    /// survive that, so it starts over; mosh just moves to a fresh UDP socket and carries on.
    func didBecomeActive() {
        EventLog.record("session active slot=\(windowSlot) state=\(state) mosh=\(mosh != nil)")
        defer { backgroundedAt = nil }
        if let mosh, state == .connected {
            mosh.wake()
            return
        }
        guard host.autoReconnect else { return }
        switch state {
        case .connected, .connecting:
            if let since = backgroundedAt, Date().timeIntervalSince(since) > 20 {
                reconnect()
            }
        case .closed:
            if backgroundedAt != nil { connect() }
        case .idle:
            break
        }
    }

    // MARK: Connection

    private func run() async {
        let host = self.host
        state = .connecting
        notice = nil
        status("connecting to \(host.username)@\(host.hostname)\(host.useMosh ? " (mosh)" : "")…")

        do {
            _ = try KeyManager.loadOrCreate()
            let validator = TOFUHostKeyValidator(endpoint: host.endpoint) { [weak self] challenge in
                await self?.askAboutHostKey(challenge) ?? false
            }
            savePromptedPassword = false
            let (client, password) = try await SSHLogin.connect(to: host, validator: validator, timeout: 10) { [weak self] retry in
                await self?.askForPassword(retry: retry)
            }
            self.client = client
            try Task.checkCancellation()
            if let password {
                // The key didn't do: keep the password for background connections (the editor,
                // the tmux sidebar), and offer to set the key up.
                if savePromptedPassword { Passwords.save(password, for: host) }
                Passwords.remember(password, for: host)
                if !KeyInstaller.wasDeclined(for: host) { offeringKeyInstall = true }
            }

            if host.useMosh {
                try await startMosh(over: client, host: host)
            } else {
                try await runShell(over: client, host: host)
                finish(nil)
            }
        } catch is CancellationError {
            finish(nil)
        } catch let error as SSHClient.CommandFailed {
            finish(host.useMosh
                ? "couldn't start mosh-server (exit \(error.exitCode)) — is mosh installed on the host?"
                : "shell exited with status \(error.exitCode)")
        } catch {
            finish(Self.describe(error))
        }
    }

    private func runShell(over client: SSHClient, host: HostProfile) async throws {
        let (queue, continuation) = AsyncStream<Input>.makeStream()
        input = continuation

        let terminal = terminalView.getTerminal()
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: terminal.cols,
            terminalRowHeight: terminal.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        let environment = [
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "COLORTERM", value: "truecolor"),
            // Lets the sidebar find this window's tmux client (sshd's default AcceptEnv allows LC_*).
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LC_AGENTTERM_TAG", value: tag),
        ]
        let startup = startupCommand

        try await client.withPTY(pty, environment: environment) { inbound, outbound in
            self.state = .connected
            let writer = Task {
                for await item in queue {
                    switch item {
                    case .bytes(let bytes):
                        try? await outbound.write(ByteBuffer(bytes: bytes))
                    case .resize(let cols, let rows):
                        try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                    }
                }
            }
            defer { writer.cancel() }

            if !startup.isEmpty {
                continuation.yield(.bytes(Array((startup + "\n").utf8)))
            }
            // This window's tty on the host, so its tmux client can be told from others'.
            Task { [weak self] in await self?.findTTY(over: client) }
            for try await output in inbound {
                switch output {
                case .stdout(var buffer), .stderr(var buffer):
                    if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                        self.terminalView.feed(byteArray: bytes[...])
                    }
                }
            }
        }
    }

    /// Starts a detached mosh-server over SSH, then drops SSH and talks mosh over UDP.
    private func startMosh(over client: SSHClient, host: HostProfile) async throws {
        // iPadOS can kill the app without warning, leaving its mosh-server running (attached to
        // tmux) until the timeout. Tag each server with this install + host + window, and stop
        // any older server with the same tag before starting its replacement.
        let tag = self.tag
        // The server's pid goes in a file per tag (macOS hides other processes' environments);
        // the environment check still catches servers started before the file existed (Linux).
        // Homebrew's mosh isn't on a Mac's PATH outside a login shell.
        let script = TmuxService.envMatch
            + "for p in $(pgrep -u \"$(id -u)\" -x mosh-server); do "
            + "envmatch $p \"AGENTTERM_TAG=\(tag)\" && kill $p; done; "
            + #"d="$HOME/.cache/agentterm"; mkdir -p "$d"; f="$d/mosh-"# + tag + #".pid"; "#
            + #"if [ -r "$f" ]; then o=$(cat "$f"); case "$(ps -o command= -p "$o" 2>/dev/null)" in *mosh-server*) kill "$o" ;; esac; fi; "#
            + "PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin\"; "
            + "out=$(AGENTTERM_TAG=\(tag) MOSH_SERVER_NETWORK_TMOUT=\(Self.moshServerTimeout) "
            + "mosh-server new -s -c 256 -l LANG=en_US.UTF-8 2>&1); printf '%s\\n' \"$out\"; "
            + #"pid=$(printf '%s\n' "$out" | sed -n 's/.*pid = \([0-9]*\).*/\1/p'); [ -n "$pid" ] && echo "$pid" > "$f"; true"#
        var output = try await client.executeCommand("sh -c \(TmuxService.shellQuote(script))")
        try? await client.close()
        self.client = nil
        try Task.checkCancellation()

        let text = output.readString(length: output.readableBytes) ?? ""
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("MOSH CONNECT ") }) else {
            throw MoshStartError(output: text)
        }
        let fields = line.split(separator: " ")
        guard fields.count >= 4, let port = UInt16(fields[2]) else { throw MoshStartError(output: text) }
        // "[mosh-server detached, pid = 1234]": its shell's tty is this window's.
        if let range = text.range(of: #"pid = (\d+)"#, options: .regularExpression),
           let pid = Int(text[range].split(separator: " ").last ?? "") {
            Task { [weak self] in await self?.findMoshTTY(serverPID: pid, host: host) }
        }

        let terminal = terminalView.getTerminal()
        moshRenderer.reset()

        let moshClient = try MoshClient(
            host: host.hostname, port: port, key: String(fields[3]), cols: terminal.cols, rows: terminal.rows
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.mosh != nil else { return }
                switch event {
                case .frame(let frame):
                    if self.state != .connected { self.state = .connected }
                    self.terminalView.feed(text: self.moshRenderer.render(frame))
                case .contact(let sinceLastHeard):
                    let notice = sinceLastHeard > 6500 ? "No contact for \(sinceLastHeard / 1000)s" : nil
                    if self.notice != notice { self.notice = notice }
                case .closed(let message):
                    self.finish(message)
                }
            }
        }
        mosh = moshClient
        EventLog.record("mosh start slot=\(windowSlot) port=\(port)")
        moshClient.start()
        // mosh delivers events in order, so this lands after the initial resize.
        let startup = startupCommand
        if !startup.isEmpty {
            moshClient.send(Array((startup + "\r").utf8))
        }
    }

    private struct MoshStartError: LocalizedError {
        let output: String
        var errorDescription: String? {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "mosh-server didn't start" + (detail.isEmpty ? "" : ": \(detail.prefix(200))")
        }
    }

    private func finish(_ message: String?) {
        EventLog.record("session finish slot=\(windowSlot) mosh=\(mosh != nil) message=\(message ?? "nil")")
        input?.finish()
        input = nil
        let client = self.client
        self.client = nil
        Task { try? await client?.close() }
        mosh?.close()
        mosh = nil
        notice = nil
        state = .closed(message)
        status(message.map { "disconnected: \($0)" } ?? "disconnected")
    }

    /// Asks over the terminal's own SSH connection which tty its shell has.
    private func findTTY(over client: SSHClient) async {
        TmuxService.setTTY(nil, for: tag)
        try? await Task.sleep(for: .milliseconds(300))
        guard var output = try? await client.executeCommand("sh -c \(TmuxService.shellQuote(TmuxService.siblingTTY))") else { return }
        let tty = (output.readString(length: output.readableBytes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tty.hasPrefix("/dev/") { TmuxService.setTTY(tty, for: tag) }
        EventLog.record("session tty slot=\(windowSlot) \(tty)")
    }

    /// mosh: the tty of mosh-server's shell, looked up over a short background connection.
    private func findMoshTTY(serverPID: Int, host: HostProfile) async {
        TmuxService.setTTY(nil, for: tag)
        for _ in 0..<3 {
            try? await Task.sleep(for: .seconds(1))
            guard let client = try? await TrustedSSH.connect(to: host) else { continue }
            let result = try? await client.executeCommand("PARENT=\(serverPID) sh -c \(TmuxService.shellQuote(TmuxService.childTTY))")
            try? await client.close()
            guard var output = result else { continue }
            let tty = (output.readString(length: output.readableBytes) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if tty.hasPrefix("/dev/") {
                TmuxService.setTTY(tty, for: tag)
                EventLog.record("session tty slot=\(windowSlot) mosh \(tty)")
                return
            }
        }
    }

    private func askForPassword(retry: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            passwordRequest = PasswordRequest(retry: retry) { [weak self] password, save in
                self?.passwordRequest = nil
                if password != nil { self?.savePromptedPassword = save }
                continuation.resume(returning: password)
            }
        }
    }

    /// Adds this device's key to the host's authorized_keys (after a password login).
    func installKey() {
        offeringKeyInstall = false
        let host = self.host
        Task {
            do {
                try await KeyInstaller.install(on: host)
                status("this device's key was added to ~/.ssh/authorized_keys: it logs in without the password now")
            } catch {
                status("couldn't add this device's key: \(error.localizedDescription)")
            }
        }
    }

    func declineKeyInstall() {
        offeringKeyInstall = false
        KeyInstaller.decline(for: host)
    }

    private func askAboutHostKey(_ partial: HostKeyChallenge.Partial) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyChallenge = HostKeyChallenge(
                endpoint: partial.endpoint,
                presentedKey: partial.presentedKey,
                knownKey: partial.knownKey
            ) { [weak self] accepted in
                self?.hostKeyChallenge = nil
                continuation.resume(returning: accepted)
            }
        }
    }

    /// Dimmed status line written into the terminal itself.
    private func status(_ text: String) {
        terminalView.feed(text: "\u{1b}[0m\r\n\u{1b}[2m[\(text)]\u{1b}[0m\r\n")
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") {
            return "login failed: add this device's public key to ~/.ssh/authorized_keys, or use a password"
        }
        if text.contains("connectTimeout") || text.contains("connectionRefused") || text.contains("NIOConnectionError") {
            return "can't reach the host (\(text))"
        }
        return text
    }
}

// MARK: - Outgoing input

#if DEBUG
extension TerminalSession {
    /// Feeds an OSC 52 copy (as tmux sends it) and a clipboard query into a session.
    static func selfTestCopy() {
        let session = TerminalSession(host: HostProfile(name: "Test", hostname: "localhost", username: "test"), windowSlot: 1, fontSize: 14, theme: TerminalTheme.named(nil))
        var out: [String] = []
        session.debugDelivered = { out.append(String(decoding: $0, as: UTF8.self)) }
        UIPasteboard.general.string = "before"
        let payload = Data("copied ✓ 漢字".utf8).base64EncodedString()
        session.terminalView.feed(text: "\u{1b}]52;c;\(payload)\u{07}")
        session.terminalView.feed(text: "\u{1b}]52;c;?\u{07}")    // a remote clipboard read must get nothing
        DispatchQueue.main.async {
            EventLog.record("selftest copy pasteboard=\(UIPasteboard.general.string ?? "nil") lastCopy=\(session.lastCopy != nil) replies=\(out)")
        }
    }

    /// Drives a tap and a drag next to a drawn tmux border through the real outgoing path.
    static func selfTestMouse() {
        let session = TerminalSession(host: HostProfile(name: "Test", hostname: "localhost", username: "test"), windowSlot: 1, fontSize: 14, theme: TerminalTheme.named(nil))
        var out: [String] = []
        session.debugDelivered = { out.append(String(decoding: $0.dropFirst(), as: UTF8.self)) }
        session.terminalView.feed(text: "\u{1b}[H" + String(repeating: "aaaaaaaaa\u{2502}bbbbbbbbbb\r\n", count: 5))
        let view = session.terminalView
        func send(_ s: String) { session.send(source: view, data: Array(s.utf8)[...]) }

        send("\u{1b}[<0;12;2M"); send("\u{1b}[<0;12;2m")             // tap 2 cells right of the border
        DispatchQueue.main.async {
            EventLog.record("selftest mouse tap -> \(out)")
            out = []
            send("\u{1b}[<0;12;3M")                                     // drag starting 2 cells off
            DispatchQueue.main.async {
                send("\u{1b}[<32;14;3M"); send("\u{1b}[<0;14;3m")
                EventLog.record("selftest mouse drag -> \(out)")
            }
        }
    }
}
#endif

extension TerminalSession {
    fileprivate func deliver(_ bytes: [UInt8]) {
        #if DEBUG
        if let debugDelivered {
            debugDelivered(bytes)
            return
        }
        #endif
        if let mosh {
            mosh.send(bytes)
        } else {
            input?.yield(.bytes(bytes))
        }
    }

    /// Holds a mouse press for one run-loop turn: SwiftTerm sends a tap's release straight after
    /// its press, while a drag's first motion comes with a later touch event. Only drags get
    /// their press moved onto a nearby tmux border (see MouseAssist).
    fileprivate func handleMouse(_ report: MouseAssist.Report) {
        if report.isPress {
            flushPendingPress(asDrag: true)
            pendingPress = report
            DispatchQueue.main.async { [weak self] in self?.flushPendingPress(asDrag: true) }
            return
        }
        if report.isRelease, pendingPress != nil {
            flushPendingPress(asDrag: false)
        } else if pendingPress != nil {
            flushPendingPress(asDrag: true)
        }
        deliver(report.bytes)
    }

    private func flushPendingPress(asDrag: Bool) {
        guard let press = pendingPress else { return }
        pendingPress = nil
        guard asDrag else {
            deliver(press.bytes)
            return
        }
        let terminal = terminalView.getTerminal()
        let snapped = MouseAssist.snap(press) { col, row in terminal.getCharacter(col: col, row: row) }
        if snapped != press {
            EventLog.record("mouse drag press \(press.x),\(press.y) snapped to border \(snapped.x),\(snapped.y)")
        }
        deliver(snapped.bytes)
    }
}

// MARK: - TerminalViewDelegate

extension TerminalSession: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated {
            // Invisible keyboard-buffer padding (see AgentTerminalView) is never sent.
            if (source as? AgentTerminalView)?.isInsertingPadding == true { return }
            if let report = MouseAssist.Report(bytes) {
                handleMouse(report)
                return
            }
            if mosh == nil, input == nil, case .closed = state, bytes == [13] {
                // Return on a dead session reconnects.
                connect()
                return
            }
            deliver(bytes)
        }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated {
            if let mosh {
                mosh.resize(cols: newCols, rows: newRows)
            } else {
                _ = input?.yield(.resize(cols: newCols, rows: newRows))
            }
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated {
            self.title = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        MainActor.assumeIsolated {
            UIApplication.shared.open(url)
        }
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        MainActor.assumeIsolated {
            UIPasteboard.general.string = text
            lastCopy = Date()
        }
    }
    // clipboardRead is deliberately left at SwiftTerm's default (nil): remote programs must not
    // be able to read the iPad clipboard with an OSC 52 query.
}

// MARK: - Sessions

/// The sessions of one window: one live session per host, so switching hosts in the sidebar
/// doesn't drop connections. Each window has its own manager.
@MainActor
final class SessionManager: ObservableObject {
    // Not @Published: each session publishes its own state; changes to the set call objectWillChange.
    private var sessions: [HostProfile.ID: TerminalSession] = [:]
    /// Each session's editor (tabs, tree), kept while the session lives.
    private var workspaces: [HostProfile.ID: EditorWorkspace] = [:]
    var windowSlot = 1

    func workspace(for session: TerminalSession) -> EditorWorkspace {
        if let existing = workspaces[session.host.id] { return existing }
        let workspace = EditorWorkspace(session: session)
        workspaces[session.host.id] = workspace
        return workspace
    }

    func session(for host: HostProfile, settings: AppSettings) -> TerminalSession {
        if let existing = sessions[host.id] {
            return existing
        }
        let session = TerminalSession(
            host: host, windowSlot: windowSlot, fontSize: settings.fontSize, theme: settings.theme(for: host)
        )
        EventLog.record("manager \(ObjectIdentifier(self).hashValue) created session slot=\(windowSlot)")
        sessions[host.id] = session
        objectWillChange.send()
        return session
    }

    func existingSession(for id: HostProfile.ID) -> TerminalSession? {
        sessions[id]
    }

    func close(_ id: HostProfile.ID) {
        sessions[id]?.disconnect()
        sessions[id] = nil
        workspaces.removeValue(forKey: id)?.close()
        objectWillChange.send()
    }

    func closeAll() {
        EventLog.record("manager \(ObjectIdentifier(self).hashValue) closeAll count=\(sessions.count)")
        sessions.keys.forEach(close)
    }

    deinit {
        EventLog.record("manager deinit \(ObjectIdentifier(self).hashValue)")
    }

    /// Pushes font, theme and host edits to live sessions.
    func apply(_ settings: AppSettings, hosts: [HostProfile]) {
        for host in hosts {
            guard let session = sessions[host.id] else { continue }
            session.update(host: host)
            session.setFontSize(settings.fontSize)
            session.apply(theme: settings.theme(for: host))
        }
    }

    func didEnterBackground() {
        sessions.values.forEach { $0.didEnterBackground() }
    }

    func didBecomeActive() {
        sessions.values.forEach { $0.didBecomeActive() }
    }
}
