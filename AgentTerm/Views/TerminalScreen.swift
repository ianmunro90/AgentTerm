import SwiftTerm
import UniformTypeIdentifiers
import SwiftUI

struct TerminalScreen: View {
    @ObservedObject var session: TerminalSession
    /// Switches this window to the editor (Explorer, Source Control, tabs).
    let onOpenEditor: () -> Void
    /// This window's shell is attached to tmux, so the tmux menu's prefix keys mean something.
    let inTmux: Bool
    /// Called when the session goes from not-connected to connected.
    let onConnected: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
    /// Upload in progress (0…1), for the banner.
    @State private var uploadProgress: Double?
    @State private var uploadMessage: String?
    @State private var showingSnippets = false
    @State private var confirmingClosePane = false
    @State private var showingCopied = false
    /// The pinch scale at the last text-size step; nil when not pinching.
    @State private var pinchAnchor: CGFloat?
    /// The tmux window's panes and zoom, for the tmux menu (nil until known).
    @State private var windowState: TmuxService.WindowState?
    @State private var renamingWindow = false
    @State private var windowName = ""
    /// Typed at the login password prompt.
    @State private var password = ""
    @State private var confirmingCloseWindow = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TerminalHost(view: session.terminalView, onPinch: pinch, onPasteItems: upload)
            .background(settings.theme(for: session.host).backgroundColor)
            .toolbarColorScheme(settings.theme(for: session.host).isLight ? .light : .dark, for: .navigationBar)
            .navigationTitle(session.title.isEmpty ? session.host.name : session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Only what's used while working; connection, host and text-size controls live in
                // the sidebar's host menu, Settings and the Terminal menu (TerminalCommands).
                ToolbarItemGroup(placement: .primaryAction) {
                    if inTmux {
                        Menu("tmux", systemImage: "rectangle.split.2x1") {
                            Button("Split Side by Side", systemImage: "rectangle.split.2x1") { tmux(.splitSideBySide) }
                            Button("Split Top and Bottom", systemImage: "rectangle.split.1x2") { tmux(.splitTopAndBottom) }
                            // Zoom only means something with several panes; while zoomed, undo it.
                            if windowState?.isZoomed == true {
                                Button("Restore Panes", systemImage: "arrow.down.right.and.arrow.up.left") { tmux(.unzoom) }
                            } else if (windowState?.panes ?? 1) > 1 {
                                Button("Zoom Pane", systemImage: "arrow.up.left.and.arrow.down.right") { tmux(.zoom) }
                            }
                            Divider()
                            // The session's windows, to switch between (the current one ticked).
                            if let windows = windowState?.windows, windows.count > 1 {
                                Section("Windows") {
                                    ForEach(windows) { window in
                                        Button {
                                            tmux(.selectWindow(window.index))
                                        } label: {
                                            Label("\(window.index): \(window.name)", systemImage: window.isActive ? "checkmark" : "macwindow")
                                        }
                                    }
                                }
                            }
                            Button("New Window", systemImage: "plus.rectangle") { tmux(.newWindow) }
                            Button("Rename Window…", systemImage: "pencil") {
                                windowName = windowState?.windows.first(where: \.isActive)?.name ?? ""
                                renamingWindow = true
                            }
                            // Never the last pane or window: that would close the window, or end the session.
                            if (windowState?.panes ?? 1) > 1 || (windowState?.windows.count ?? 1) > 1 {
                                Divider()
                            }
                            if (windowState?.panes ?? 1) > 1 {
                                Button("Close Pane…", systemImage: "xmark.rectangle", role: .destructive) {
                                    confirmingClosePane = true
                                }
                            }
                            if (windowState?.windows.count ?? 1) > 1 {
                                Button("Close Window…", systemImage: "xmark.square", role: .destructive) {
                                    confirmingCloseWindow = true
                                }
                            }
                        }
                        .disabled(session.state != .connected)
                    }
                    // The system paste control doesn't trigger iOS's "Allow Paste" prompt. Text is
                    // typed in; images and files are uploaded and their path typed in instead.
                    PasteButton(supportedContentTypes: [.plainText, .image, .fileURL]) { providers in
                        paste(providers)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(session.state != .connected)
                    Button("Editor", systemImage: "chevron.left.forwardslash.chevron.right", action: onOpenEditor)
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                        .disabled(session.state != .connected)
                    Button("Snippets", systemImage: "text.badge.plus") { showingSnippets = true }
                        .keyboardShortcut("j", modifiers: .command)
                        .disabled(session.state != .connected)
                        .popover(isPresented: $showingSnippets) {
                            SnippetsView { snippet, pressReturn in
                                session.sendInput(snippet.text, pressReturn: pressReturn)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    session.terminalView.focusUnlessCovered()
                                }
                            }
                            .frame(minWidth: 380, idealWidth: 420, minHeight: 560, idealHeight: 680)
                        }
                }
            }
            .focusedSceneValue(\.activeTerminal, session)
            // Keep the tmux menu current while this window shows tmux: on connect, every 15 s
            // (a zoom or split made from the keyboard), and on return to the foreground.
            .task(id: inTmux && session.state == .connected && scenePhase == .active) {
                guard inTmux, session.state == .connected, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await refreshWindowState()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
            .confirmationDialog("Close this tmux window?", isPresented: $confirmingCloseWindow, titleVisibility: .visible) {
                Button("Close Window", role: .destructive) { tmux(.closeWindow) }
            } message: {
                Text("Ends everything running in its panes.")
            }
            .alert("Rename Window", isPresented: $renamingWindow) {
                TextField("Name", text: $windowName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Rename") {
                    let name = windowName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { tmux(.renameWindow(name)) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Close the active pane?", isPresented: $confirmingClosePane, titleVisibility: .visible) {
                Button("Close Pane", role: .destructive) { tmux(.close) }
            } message: {
                Text("Ends whatever is running in it. Tap a pane first to choose which one.")
            }
            .overlay {
                if pinchAnchor != nil {
                    Text("\(Int(settings.fontSize)) pt")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
            .onDrop(of: [.fileURL, .image, .movie, .data], isTargeted: nil) { providers in
                upload(providers)
                return true
            }
            .onChange(of: lock.isLocked) { _, locked in
                if !locked { session.terminalView.focusUnlessCovered() }
            }
            .overlay(alignment: .top) {
                // Only problems are shown here; the sidebar dot shows the connection state.
                if let progress = uploadProgress {
                    Label("Uploading… \(Int(progress * 100))%", systemImage: "arrow.up.circle")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                } else if let message = uploadMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                } else if let handoff = session.handoff {
                    Label(handoff, systemImage: "sparkles")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.opacity)
                } else if let notice = session.notice {
                    Label(notice, systemImage: "wifi.exclamationmark")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                } else if showingCopied {
                    Label("Copied to clipboard", systemImage: "doc.on.doc.fill")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: session.lastCopy) {
                withAnimation(.snappy) { showingCopied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    withAnimation(.easeOut) { showingCopied = false }
                }
            }
            .onChange(of: session.state) { old, new in
                if new == .connected, old != .connected { onConnected() }
            }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("-showSnippets") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showingSnippets = true }
                }
                // -landscape: turn the window (simulator screenshots).
                if CommandLine.arguments.contains("-landscape"),
                   let scene = session.terminalView.window?.windowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
                #endif
                if session.state == .idle { session.connect() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    session.terminalView.focusUnlessCovered()
                }
            }
            .modifier(LoginPrompts(session: session, password: $password))
    }
}

extension TerminalScreen {
    fileprivate func paste(_ providers: [NSItemProvider]) {
        if let text = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            _ = text.loadObject(ofClass: String.self) { string, _ in
                guard let string, !string.isEmpty else { return }
                DispatchQueue.main.async {
                    session.paste(string)
                    session.terminalView.focusUnlessCovered()
                }
            }
        } else {
            upload(providers)
        }
    }

    /// Uploads dropped or pasted files to the host's upload folder and types their paths.
    fileprivate func upload(_ providers: [NSItemProvider]) {
        guard session.state == .connected, uploadProgress == nil else { return }
        let session = self.session
        uploadProgress = 0
        Task {
            let items = await ItemLoader.load(providers)
            guard !items.isEmpty else {
                uploadProgress = nil
                return
            }
            do {
                let paths = try await Uploader.upload(items, to: session.host) { fraction in
                    Task { @MainActor in uploadProgress = fraction }
                }
                // Pasted, not typed: Claude Code turns pasted image paths into attachments.
                session.paste(Uploader.shellQuoted(paths) + " ")
                uploadMessage = paths.count == 1 ? "Uploaded to \(Uploader.displayDirectory(for: session.host))" : "Uploaded \(paths.count) files"
            } catch {
                uploadMessage = "Upload failed: \(error.localizedDescription)"
            }
            uploadProgress = nil
            session.terminalView.focusUnlessCovered()
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { uploadMessage = nil }
        }
    }

    /// Fingers must spread or close this much more, relative to the last step, per point.
    /// Measuring from the last step (not the start) also stops jitter flipping the size.
    private static let pinchStep: CGFloat = 1.18

    /// Pinch changes the app-wide text size in whole points (9–28, as in Settings).
    fileprivate func pinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            // The view forwards a pinch only once it's clearly a zoom, usually mid-gesture.
            guard let anchor = pinchAnchor else {
                withAnimation(.easeOut(duration: 0.15)) { pinchAnchor = gesture.scale }
                return
            }
            let ratio = gesture.scale / anchor
            var size = settings.fontSize
            if ratio >= Self.pinchStep {
                size = min(28, size + 1)
            } else if ratio <= 1 / Self.pinchStep {
                size = max(9, size - 1)
            } else {
                return
            }
            pinchAnchor = gesture.scale
            if size != settings.fontSize {
                settings.fontSize = size
                UISelectionFeedbackGenerator().selectionChanged()
            }
        default:
            withAnimation(.easeOut(duration: 0.3)) { pinchAnchor = nil }
        }
    }

    /// Runs a tmux pane action for this window's tmux client, then gives the keyboard back.
    fileprivate func tmux(_ action: TmuxService.PaneAction) {
        let session = self.session
        Task {
            do {
                if try await !TmuxService.perform(action, on: session.host, tag: session.tag) {
                    EventLog.record("tmux \(action): no tmux client for this window")
                }
            } catch {
                EventLog.record("tmux \(action) failed: \(error)")
            }
            session.terminalView.focusUnlessCovered()
            await refreshWindowState()
        }
    }

    private func refreshWindowState() async {
        let state = try? await TmuxService.windowState(on: session.host, tag: session.tag)
        if state != windowState { windowState = state }
    }
}

/// Hosts the session's long-lived TerminalView.
private struct TerminalHost: UIViewRepresentable {
    let view: TerminalView
    let onPinch: (UIPinchGestureRecognizer) -> Void
    let onPasteItems: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> TerminalView {
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        (uiView as? AgentTerminalView)?.onPinch = onPinch
        (uiView as? AgentTerminalView)?.onPasteItems = onPasteItems
    }
}

/// The prompts while logging in: an unknown or changed host key, a password, and afterwards
/// the offer to log in with this device's key from now on.
struct LoginPrompts: ViewModifier {
    @ObservedObject var session: TerminalSession
    @Binding var password: String

    func body(content: Content) -> some View {
        content
            #if DEBUG
            // Answers prompts in the simulator (no taps there): -trustHostKeys, -typePassword <pw>,
            // -acceptKeyInstall.
            .onChange(of: session.hostKeyChallenge?.id) {
                if CommandLine.arguments.contains("-trustHostKeys") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { session.hostKeyChallenge?.respond(true) }
                }
            }
            .onChange(of: session.passwordRequest?.id) {
                guard let index = CommandLine.arguments.firstIndex(of: "-typePassword"), CommandLine.arguments.indices.contains(index + 1),
                      session.passwordRequest?.retry == false else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { session.passwordRequest?.respond(CommandLine.arguments[index + 1], false) }
            }
            .onChange(of: session.offeringKeyInstall) {
                if session.offeringKeyInstall, CommandLine.arguments.contains("-acceptKeyInstall") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { session.installKey() }
                }
            }
            #endif
            .alert(
                session.passwordRequest?.retry == true ? "Wrong Password" : "Password",
                isPresented: Binding(get: { session.passwordRequest != nil }, set: { _ in }),
                presenting: session.passwordRequest
            ) { request in
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button("Log In") { respond(request, save: false) }
                Button("Log In and Save") { respond(request, save: true) }
                Button("Cancel", role: .cancel) {
                    password = ""
                    request.respond(nil, false)
                }
            } message: { request in
                Text(request.retry ? "Try again for \(session.host.username)@\(session.host.hostname)."
                     : "\(session.host.username)@\(session.host.hostname) didn't accept this device's key. "
                        + "“Log In” remembers the password until AgentTerm quits; “Log In and Save” keeps it in this device's Keychain.")
            }
            .alert("Log In With a Key?", isPresented: $session.offeringKeyInstall) {
                Button("Add Key") { session.installKey() }
                Button("Not Now", role: .cancel) { session.declineKeyInstall() }
            } message: {
                Text("AgentTerm can add this device's public key to ~/.ssh/authorized_keys on \(session.host.hostname), so it logs in without the password from now on.")
            }
            .alert(
                session.hostKeyChallenge?.isMismatch == true ? "Host Key Changed" : "Unknown Host",
                isPresented: Binding(get: { session.hostKeyChallenge != nil }, set: { _ in }),
                presenting: session.hostKeyChallenge
            ) { challenge in
                if challenge.isMismatch {
                    Button("Replace Saved Key", role: .destructive) { challenge.respond(true) }
                } else {
                    Button("Trust") { challenge.respond(true) }
                }
                Button("Cancel", role: .cancel) { challenge.respond(false) }
            } message: { challenge in
                if let known = challenge.knownKey {
                    Text("\(challenge.endpoint) presented a different host key than the one saved. This could mean someone is intercepting the connection.\n\nSaved: \(KnownHosts.fingerprint(known))\nNow: \(KnownHosts.fingerprint(challenge.presentedKey))")
                } else {
                    Text("First connection to \(challenge.endpoint).\n\n\(KnownHosts.fingerprint(challenge.presentedKey))")
                }
            }
    }

    private func respond(_ request: PasswordRequest, save: Bool) {
        let typed = password
        password = ""
        request.respond(typed, save)
    }
}

extension TerminalView {
    /// Takes the keyboard, unless a sheet is over the terminal (Settings, Check Server, the
    /// setup guide): its keyboard would come up over the sheet.
    func focusUnlessCovered() {
        guard window?.rootViewController?.presentedViewController == nil else { return }
        #if DEBUG
        if CommandLine.arguments.contains("-noFocus") { return }   // screenshots without the keyboard
        #endif
        _ = becomeFirstResponder()
    }
}
