import SwiftUI

struct KeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var publicKey = ""
    @State private var error: String?
    @State private var copied = false
    @State private var confirmingRegenerate = false
    @State private var importing = false
    @State private var importText = ""
    @State private var passphrase = ""
    @State private var importError: String?
    @State private var choosingFile = false

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Public key")
                } footer: {
                    Text("Add this line to `~/.ssh/authorized_keys` on each host, or log in once with a password and let AgentTerm add it. The private key never leaves this device's Keychain.")
                }

                Section {
                    Button("Generate New Key…", systemImage: "arrow.triangle.2.circlepath", role: .destructive) {
                        confirmingRegenerate = true
                    }
                    Button("Import Private Key…", systemImage: "square.and.arrow.down") {
                        importing = true
                    }
                } footer: {
                    Text("Replacing the key means re-authorizing this device on every host.")
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("This Device's Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Replace this device's SSH key?", isPresented: $confirmingRegenerate, titleVisibility: .visible) {
                Button("Generate New Key", role: .destructive) {
                    perform { try KeyManager.regenerate() }
                }
            }
            .sheet(isPresented: $importing) {
                importSheet
            }
            .onAppear(perform: refresh)
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $importText)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 220)
                    Button("Choose File…", systemImage: "folder") { choosingFile = true }
                } header: {
                    Text("OpenSSH Ed25519 private key")
                } footer: {
                    Text("Paste it, or choose the file (usually `~/.ssh/id_ed25519`). RSA keys aren't supported.")
                }
                Section {
                    SecureField("Passphrase (if it has one)", text: $passphrase)
                }
                if let importError {
                    Section { Text(importError).foregroundStyle(.red) }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Import Private Key")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data, .text]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), data.count < 64_000, let text = String(data: data, encoding: .utf8) {
                    importText = text
                    importError = nil
                } else {
                    importError = "That file isn't a text key file."
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { closeImport() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            try KeyManager.importOpenSSH(importText, passphrase: passphrase)
                            closeImport()
                            error = nil
                            refresh()
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                    .disabled(importText.isEmpty)
                }
            }
        }
    }

    private func closeImport() {
        importText = ""
        passphrase = ""
        importError = nil
        importing = false
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        copied = false
        do {
            publicKey = KeyManager.openSSHPublicKey(for: try KeyManager.loadOrCreate())
        } catch {
            self.error = error.localizedDescription
        }
    }
}
