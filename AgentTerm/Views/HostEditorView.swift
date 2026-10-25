import SwiftUI

struct HostEditorView: View {
    @EnvironmentObject private var hosts: HostStore
    @Environment(\.dismiss) private var dismiss
    @State private var host: HostProfile
    @State private var forgotKey = false
    /// The saved password (empty: none), saved with the host.
    @State private var password = ""
    @State private var keyInstall: KeyInstallState?

    enum KeyInstallState: Equatable {
        case working, done, failed(String)
    }

    init(host: HostProfile) {
        _host = State(initialValue: host)
    }

    private var isNew: Bool { !hosts.hosts.contains { $0.id == host.id } }
    private var canSave: Bool { !host.hostname.isEmpty && !host.username.isEmpty && (1...65535).contains(host.port) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name)
                    TextField("Hostname or IP", text: $host.hostname)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("Username", text: $host.username)
                        .textContentType(.username)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Section {
                    SecureField("Password (optional)", text: $password)
                        .textContentType(.password)
                    if !isNew, KnownHosts.key(for: host.endpoint) != nil, !password.isEmpty || Passwords.password(for: host) != nil {
                        Button {
                            installKey()
                        } label: {
                            switch keyInstall {
                            case .working: Label("Adding Key…", systemImage: "key")
                            case .done: Label("Key Added", systemImage: "checkmark")
                            default: Label("Add This Device's Key to the Server", systemImage: "key")
                            }
                        }
                        .disabled(keyInstall == .working || keyInstall == .done)
                    }
                } header: {
                    Text("Login")
                } footer: {
                    switch keyInstall {
                    case .failed(let message): Text(message).foregroundStyle(.red)
                    default:
                        Text("AgentTerm logs in with this device's key (the key button at the bottom of the sidebar), then with a password if the server asks for one. A password entered here is kept in this device's Keychain; leave it empty to be asked when needed.")
                    }
                }

                Section {
                    Toggle("Keep Sessions in tmux", isOn: Binding(
                        get: { host.startupCommand == HostProfile.tmuxStartupCommand },
                        set: { host.startupCommand = $0 ? HostProfile.tmuxStartupCommand : "" }
                    ))
                    TextField("Startup command", text: $host.startupCommand)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Reconnect when reopened", isOn: $host.autoReconnect)
                } footer: {
                    Text("Typed into the shell after login. `tmux new -A -s main{window}` keeps your session alive when the app is suspended. On iPad, `{window}` becomes nothing in the first window and `-2`, `-3`… in others, so each window gets its own tmux session.")
                }

                Section {
                    Toggle("Use mosh", isOn: $host.useMosh)
                } footer: {
                    Text("Logs in over SSH only to start `mosh-server`, then stays connected over UDP (ports 60000–61000) through network changes and app suspension. Needs mosh installed on the host. No scrollback in mosh itself — use tmux.")
                }

                Section {
                    TextField("Upload folder", text: $host.uploadDirectory)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Files")
                } footer: {
                    Text("Where dropped, pasted and shared files go: in your home folder (`uploads`), or a full path.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $host.themeID) {
                        Text("App Default").tag(String?.none)
                        ForEach(TerminalTheme.all) { theme in
                            Text(theme.name).tag(String?.some(theme.id))
                        }
                    }
                }

                if !isNew, KnownHosts.key(for: host.endpoint) != nil {
                    Section {
                        Button(forgotKey ? "Host Key Forgotten" : "Forget Saved Host Key", role: .destructive) {
                            KnownHosts.forget(host.endpoint)
                            forgotKey = true
                        }
                        .disabled(forgotKey)
                    } footer: {
                        Text(KnownHosts.fingerprint(KnownHosts.key(for: host.endpoint) ?? ""))
                            .font(.caption.monospaced())
                    }
                }
            }
            .onAppear { password = Passwords.saved(for: host) ?? "" }
            .hidesTerminalKeyboard()
            .navigationTitle(isNew ? "New Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
                        hosts.upsert(host)
                        Passwords.save(password, for: host)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private func installKey() {
        keyInstall = .working
        let host = host
        if !password.isEmpty { Passwords.remember(password, for: host) }
        Task {
            do {
                try await KeyInstaller.install(on: host)
                keyInstall = .done
            } catch {
                keyInstall = .failed("Couldn't add the key: \(error.localizedDescription)")
            }
        }
    }
}
