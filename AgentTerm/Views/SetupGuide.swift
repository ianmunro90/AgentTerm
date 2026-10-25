import SwiftUI

/// Adds a server step by step: where it is, how to log in, a first connection (checking the
/// host key and the login), setting up this device's key after a password login, then what
/// the server has of the tools AgentTerm uses, with the missing ones to install.
struct SetupGuide: View {
    /// The server added (not called if the guide is cancelled).
    let onFinish: (HostProfile) -> Void
    @EnvironmentObject private var hosts: HostStore
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.welcome
    @State private var host = HostProfile(name: "", hostname: "", username: "")
    @State private var usesPassword = true
    @State private var password = ""
    @State private var savePassword = true
    @State private var publicKey = ""
    @State private var copied = false
    @State private var connecting = false
    @State private var failure: String?
    @State private var hostKey: HostKeyQuestion?
    @State private var keyInstall: KeyInstallState?
    @State private var keepInTmux = true

    enum Step: Int, Comparable {
        case welcome, server, login, connect, key, tools

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum KeyInstallState: Equatable { case working, done, failed(String) }

    /// An unknown host key, waiting for Trust or Cancel.
    struct HostKeyQuestion {
        let challenge: HostKeyChallenge.Partial
        let respond: (Bool) -> Void
    }

    private var serverIsValid: Bool {
        !host.hostname.trimmingCharacters(in: .whitespaces).isEmpty && !host.username.isEmpty && (1...65535).contains(host.port)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Back on the left (the form steps only: Connecting has its own buttons),
                    // Cancel on the right: on the same side iOS 26 runs them into one capsule.
                    if step == .server || step == .login {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                step = Step(rawValue: step.rawValue - 1) ?? .welcome
                            } label: {
                                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            hostKey?.respond(false)
                            if !hosts.hosts.contains(where: { $0.id == host.id }) { Passwords.forget(host) }
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled()
        .pageSizedSheet()
        .hidesTerminalKeyboard()
        .onAppear {
            publicKey = (try? KeyManager.loadOrCreate()).map(KeyManager.openSSHPublicKey(for:)) ?? ""
            #if DEBUG
            debugRun()
            #endif
        }
        #if DEBUG
        .onChange(of: hostKey != nil) {
            if hostKey != nil, CommandLine.arguments.contains("-trustHostKeys") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { answer(true) }
            }
        }
        .onChange(of: step) {
            if step == .key, CommandLine.arguments.contains("-acceptKeyInstall") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { installKey() }
            }
        }
        #endif
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome"
        case .server: "Server"
        case .login: "Login"
        case .connect: "Connecting"
        case .key: "This Device's Key"
        case .tools: "Tools"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcome
        case .server: serverForm
        case .login: loginForm
        case .connect: connectView
        case .key: keyView
        case .tools: toolsView
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("Welcome to AgentTerm").font(.largeTitle.bold())
                Text("A terminal for your servers over SSH or mosh, with a read-only code editor that works on the server and hands files, selections and problems to Claude Code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }
            VStack(alignment: .leading, spacing: 14) {
                bullet("server.rack", "Add a server: its address and your username.")
                bullet("key", "Log in with a password, or this device's own key.")
                bullet("checklist", "See what the server has of the tools AgentTerm uses, and install what you want.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            Spacer()
            Button {
                step = .server
            } label: {
                Text("Add a Server").frame(maxWidth: 360)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .scrollsWhenTooTall()
    }

    /// An icon in a fixed-width column (the symbols differ in width), so the lines start level.
    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var serverForm: some View {
        Form {
            Section {
                TextField("Address (hostname or IP)", text: $host.hostname)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                TextField("Username", text: $host.username)
                    .textContentType(.username)
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Name (optional)", text: $host.name)
            } footer: {
                Text("The computer you connect to over SSH, as you'd write it in `ssh username@address`. Port 22 unless the server uses another.")
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            nextButton("Next", enabled: serverIsValid) {
                host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
                step = .login
            }
        }
    }

    private var loginForm: some View {
        Form {
            Section {
                Picker("Log in with", selection: $usesPassword) {
                    Text("Password").tag(true)
                    Text("This Device's Key").tag(false)
                }
                .pickerStyle(.segmented)
            }
            if usesPassword {
                Section {
                    SecureField("Password for \(host.username)", text: $password)
                        .textContentType(.password)
                    Toggle("Save in Keychain", isOn: $savePassword)
                } footer: {
                    Text("After logging in, AgentTerm can add this device's key to the server so later logins don't need the password. The password is kept only on this device.")
                }
            } else {
                Section {
                    Text(publicKey)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = publicKey
                        copied = true
                    }
                    ShareLink("Share Public Key", item: publicKey)
                } header: {
                    Text("This device's public key")
                } footer: {
                    Text("Add this line to `~/.ssh/authorized_keys` for \(host.username) on the server first. The private key never leaves this device.")
                }
            }
            nextButton("Connect", enabled: !usesPassword || !password.isEmpty) { connect() }
        }
    }

    private var connectView: some View {
        VStack(spacing: 20) {
            Spacer()
            if let question = hostKey {
                let changed = question.challenge.knownKey != nil
                Image(systemName: changed ? "exclamationmark.shield" : "lock.shield").font(.system(size: 44))
                    .foregroundStyle(changed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                Text(changed ? "\(host.hostname)'s Key Has Changed" : "Is this \(host.hostname)?").font(.title2.bold())
                Text(changed
                     ? "This device trusted a different key for this server before. That happens when a server is reinstalled, but could also mean someone is intercepting the connection: check the fingerprint before trusting it."
                     : "This is the first connection to this server. Check its key's fingerprint with the server's administrator, or on the server with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then trust it.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Text(KnownHosts.fingerprint(question.challenge.presentedKey))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 16) {
                    Button("Cancel", role: .cancel) { answer(false) }
                        .buttonStyle(.bordered)
                    Button("Trust") { answer(true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else if let failure {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(.orange)
                Text("Couldn't Connect").font(.title2.bold())
                Text(failure)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                HStack(spacing: 16) {
                    Button("Change Settings") { step = .server }
                        .buttonStyle(.bordered)
                    Button("Try Again") { connect() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            } else {
                ProgressView()
                Text("Connecting to \(host.username)@\(host.hostname)…").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(32)
        .scrollsWhenTooTall()
    }

    private var keyView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "key.horizontal").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Log In With a Key From Now On?").font(.title2.bold())
            Text("AgentTerm can add this device's public key to `~/.ssh/authorized_keys` for \(host.username), as `ssh-copy-id` does. Later logins then use the key, and the background connections the editor and session list make don't need the password.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if case .failed(let message) = keyInstall {
                Text(message).foregroundStyle(.red)
            }
            HStack(spacing: 16) {
                Button("Not Now") {
                    KeyInstaller.decline(for: host)
                    step = .tools
                }
                .buttonStyle(.bordered)
                Button {
                    installKey()
                } label: {
                    if keyInstall == .working { ProgressView() } else { Text("Add Key") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyInstall == .working)
            }
            .controlSize(.large)
            Spacer()
        }
        .padding(32)
        .scrollsWhenTooTall()
    }

    private var toolsView: some View {
        VStack(spacing: 0) {
            // Sessions in tmux by default when it's there (or once it's installed).
            ServerCheckView(host: host) { report in keepInTmux = report.isInstalled(.tmux) }
            VStack(spacing: 12) {
                Toggle("Keep sessions in tmux", isOn: $keepInTmux)
                    .frame(maxWidth: 520)
                Text("Runs `\(HostProfile.tmuxStartupCommand)` after login, so what's running survives the app being suspended. Needs tmux on the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
                Toggle("Lock AgentTerm with \(LockSettings.methodName)", isOn: $lock.isEnabled)
                    .frame(maxWidth: 520)
                Button {
                    finish()
                } label: {
                    Text("Open Terminal").frame(maxWidth: 360)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func nextButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Section {
            Button(action: action) {
                Text(title).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!enabled)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: Actions

    #if DEBUG
    /// -setupHost user@host:port [-typePassword <pw>] [-setupStep server|login]: fills the guide
    /// in and, without -setupStep, connects.
    private func debugRun() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "-setupHost"), arguments.indices.contains(index + 1) else { return }
        let spec = arguments[index + 1]
        host.username = String(spec.prefix { $0 != "@" })
        let rest = spec.dropFirst(host.username.count + 1)
        host.hostname = String(rest.prefix { $0 != ":" })
        host.port = Int(rest.dropFirst(host.hostname.count + 1)) ?? 22
        if let p = arguments.firstIndex(of: "-typePassword"), arguments.indices.contains(p + 1) {
            password = arguments[p + 1]
        } else {
            usesPassword = false
        }
        if let s = arguments.firstIndex(of: "-setupStep"), arguments.indices.contains(s + 1) {
            step = arguments[s + 1] == "login" ? .login : .server
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connect() }
        }
    }
    #endif

    /// A first connection: the host key (asked about here), then the login.
    private func connect() {
        step = .connect
        failure = nil
        connecting = true
        Passwords.forget(host)
        if usesPassword { Passwords.remember(password, for: host) }
        let host = host
        Task {
            defer { connecting = false }
            let validator = TOFUHostKeyValidator(endpoint: host.endpoint) { challenge in
                await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        hostKey = HostKeyQuestion(challenge: challenge) { trusted in
                            hostKey = nil
                            continuation.resume(returning: trusted)
                        }
                    }
                }
            }
            do {
                let (client, usedPassword) = try await SSHLogin.connect(to: host, validator: validator, timeout: 10)
                try? await client.close()
                if let usedPassword, savePassword { Passwords.save(usedPassword, for: host) }
                step = usedPassword == nil ? .tools : .key
            } catch {
                failure = Self.describe(error, usesPassword: usesPassword)
            }
        }
    }

    private func answer(_ trusted: Bool) {
        hostKey?.respond(trusted)
    }

    private func installKey() {
        keyInstall = .working
        let host = host
        Task {
            do {
                try await KeyInstaller.install(on: host)
                keyInstall = .done
                step = .tools
            } catch {
                keyInstall = .failed("Couldn't add the key: \(error.localizedDescription)")
            }
        }
    }

    private func finish() {
        var host = host
        if host.name.trimmingCharacters(in: .whitespaces).isEmpty { host.name = host.hostname }
        if keepInTmux { host.startupCommand = HostProfile.tmuxStartupCommand }
        hosts.upsert(host)
        onFinish(host)
        dismiss()
    }

    private static func describe(_ error: Error, usesPassword: Bool) -> String {
        if error is HostKeyRejected { return "The server's key wasn't trusted." }
        if let error = error as? SSHLogin.Failed {
            if usesPassword, !error.serverTakesPasswords {
                return "The server doesn't allow password logins. Add this device's key to it instead (choose This Device's Key under Login)."
            }
            return usesPassword ? "The username or password wasn't accepted." : "The server didn't accept this device's key. Check that its public key is in ~/.ssh/authorized_keys for this user."
        }
        let text = String(describing: error)
        if text.contains("connectTimeout") || text.contains("Timeout") {
            return "No answer from the server within 10 seconds. Check the address and port, and that this device can reach it (VPN, firewall)."
        }
        if text.contains("connectionRefused") || text.contains("Connection refused") {
            return "The server refused the connection: nothing is listening for SSH on that port."
        }
        if text.contains("NIOConnectionError") || text.contains("resolve") {
            return "Couldn't reach the server: \(error.localizedDescription)"
        }
        return error.localizedDescription
    }
}

extension View {
    /// A sheet the size of a page on iPad (iPadOS 18+), for lists that need the room.
    @ViewBuilder
    func pageSizedSheet() -> some View {
        if #available(iOS 18.0, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}

extension View {
    /// For a sheet over the terminal: puts its keyboard away (it otherwise stays up over the
    /// sheet), again after the terminal's own delayed focus.
    func hidesTerminalKeyboard() -> some View {
        task {
            for delay in [0.0, 0.6] {
                try? await Task.sleep(for: .seconds(delay))
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
}

extension View {
    /// Centred in the space it has (its Spacers share it out), scrolling instead when the
    /// content is taller, as with the largest accessibility text sizes.
    func scrollsWhenTooTall() -> some View {
        GeometryReader { proxy in
            ScrollView {
                frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
