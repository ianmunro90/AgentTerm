import SwiftUI
import UIKit

struct ShareView: View {
    let providers: [NSItemProvider]
    let onDone: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var hosts: HostStore
    @State private var phase = Phase.unlocking
    @State private var items: [Uploader.Item] = []
    @State private var hostID: HostProfile.ID?
    @State private var progress = 0.0

    private static let lastHostKey = "share.lastHost"

    enum Phase: Equatable {
        case unlocking, locked, loading, ready, uploading, done([String]), failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to AgentTerm")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Upload", action: upload)
                            .disabled(phase != .ready || items.isEmpty || selectedHost == nil)
                    }
                }
        }
        .task { await start() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .unlocking, .loading:
            ProgressView()
        case .locked:
            ContentUnavailableView {
                Label("Locked", systemImage: "lock.fill")
            } actions: {
                Button("Unlock with \(LockSettings.methodName)") { Task { await start() } }
                    .buttonStyle(.borderedProminent)
            }
        case .ready, .uploading, .failed:
            Form {
                Section("Send to") {
                    Picker("Host", selection: $hostID) {
                        ForEach(hosts.hosts) { host in
                            Text(host.name.isEmpty ? host.hostname : host.name).tag(Optional(host.id))
                        }
                    }
                    .disabled(phase == .uploading)
                }
                Section {
                    ForEach(items, id: \.localURL) { item in
                        Label(item.filename, systemImage: "doc")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text(items.count == 1 ? "1 item" : "\(items.count) items")
                } footer: {
                    Text("Saved to \(selectedHost.map(Uploader.displayDirectory(for:)) ?? "~/uploads") on the host. The path is copied so you can paste it into a terminal or Claude Code.")
                }
                if phase == .uploading {
                    Section { ProgressView(value: progress) }
                }
                if case .failed(let message) = phase {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
        case .done(let paths):
            ContentUnavailableView {
                Label("Uploaded", systemImage: "checkmark.circle.fill")
            } description: {
                Text(paths.joined(separator: "\n")).font(.footnote.monospaced())
                Text("Path copied to the clipboard.")
            }
        }
    }

    private var selectedHost: HostProfile? {
        hosts.hosts.first { $0.id == hostID }
    }

    private func start() async {
        if LockSettings.isEnabled {
            phase = .unlocking
            guard await LockSettings.authenticate(reason: "Unlock AgentTerm to upload to your hosts.") else {
                phase = .locked
                return
            }
        }
        phase = .loading
        let last = SharedStore.defaults.string(forKey: Self.lastHostKey).flatMap(UUID.init(uuidString:))
        hostID = hosts.hosts.first { $0.id == last }?.id ?? hosts.hosts.first?.id
        items = await ItemLoader.load(providers)
        phase = items.isEmpty ? .failed("Nothing here can be uploaded.") : .ready
    }

    private func upload() {
        guard let host = selectedHost else { return }
        SharedStore.defaults.set(host.id.uuidString, forKey: Self.lastHostKey)
        phase = .uploading
        progress = 0
        Task {
            do {
                let paths = try await Uploader.upload(items, to: host) { fraction in
                    Task { @MainActor in progress = fraction }
                }
                UIPasteboard.general.string = Uploader.shellQuoted(paths)
                phase = .done(paths)
                try? await Task.sleep(for: .seconds(1.5))
                onDone()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
