import SwiftTerm
import SwiftUI

/// What a server has of the tools AgentTerm uses, with the missing ones to tick and install.
/// Installing runs in a terminal of its own (InstallView), so every command shows and sudo
/// can ask for a password; afterwards the server is checked again.
struct ServerCheckView: View {
    let host: HostProfile
    /// Each new report (first check, and after installing).
    var onReport: ((ServerCheck.Report) -> Void)?
    @State private var report: ServerCheck.Report?
    @State private var failure: String?
    @State private var selected: Set<ServerCheck.Tool> = []
    @State private var installing: String?

    #if DEBUG
    nonisolated(unsafe) private static var debugInstalled = false
    #endif

    /// Ticked to start with, when missing: what most people want.
    private static let recommended: Set<ServerCheck.Tool> = [.tmux, .git, .ripgrep]

    var body: some View {
        List {
            if let report {
                Section {
                    LabeledContent("System", value: [report.system, report.architecture].filter { !$0.isEmpty }.joined(separator: " · "))
                    LabeledContent("Installs with", value: report.packageManager.map { $0 == "brew" ? "Homebrew" : $0 } ?? "no package manager found")
                } footer: {
                    if report.packageManager != nil, report.packageManager != "brew", !report.isRoot, !report.hasSudo {
                        Text("System packages need sudo, which isn't available to \(host.username): ask the server's administrator for those.")
                    }
                }
                Section {
                    ForEach(ServerCheck.Tool.allCases) { tool in
                        row(tool, report)
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Everything is optional: the terminal works without any of it. System packages install with sudo (you'll be asked for your password in the install terminal); language servers, .NET and Claude Code install into your home folder.")
                }
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn't Check the Server", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await check() } }
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking \(host.hostname)…").foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let report, !selected.isEmpty {
                Button {
                    installing = ServerCheck.installScript(selected, report: report)
                } label: {
                    Text("Install \(selected.count == 1 ? "1 Item" : "\(selected.count) Items")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .refreshable { await check() }
        .task { if report == nil { await check() } }
        // The terminal behind keeps the keyboard up otherwise.
        .hidesTerminalKeyboard()
        .sheet(item: Binding(get: { installing.map(InstallScript.init) }, set: { if $0 == nil { installing = nil } })) { script in
            InstallView(host: host, script: script.text) {
                installing = nil
                Task { await check() }
            }
        }
    }

    private func row(_ tool: ServerCheck.Tool, _ report: ServerCheck.Report) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: tool.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.name)
                Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                if let version = report.found[tool], !version.isEmpty {
                    Text(version).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                } else if tool == .languageServers {
                    Text(report.serverSummary).font(.caption.monospaced()).foregroundStyle(.secondary)
                } else if tool == .node, let old = report.oldNode {
                    Text("\(old) is too old: the language servers need 18 or later").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if report.isInstalled(tool) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Installed")
            } else if report.canInstall(tool) {
                Toggle("Install \(tool.name)", isOn: Binding(
                    get: { selected.contains(tool) },
                    set: { if $0 { selected.insert(tool) } else { selected.remove(tool) } }
                ))
                .labelsHidden()
            } else {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func check() async {
        failure = nil
        do {
            let report = try await ServerCheck.check(host)
            self.report = report
            onReport?(report)
            selected = Set(Self.recommended.filter { !report.isInstalled($0) && report.canInstall($0) })
            #if DEBUG
            // -installTools tmux,git,…: tick those and install, once.
            if let index = CommandLine.arguments.firstIndex(of: "-installTools"), CommandLine.arguments.indices.contains(index + 1),
               !Self.debugInstalled {
                Self.debugInstalled = true
                selected = Set(CommandLine.arguments[index + 1].split(separator: ",").compactMap { ServerCheck.Tool(rawValue: String($0)) })
                    .filter { !report.isInstalled($0) && report.canInstall($0) }
                if !selected.isEmpty { installing = ServerCheck.installScript(selected, report: report) }
            }
            #endif
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct InstallScript: Identifiable {
    let text: String
    var id: String { text }
}

/// A terminal that logs in and runs the install script, then stays open to read.
struct InstallView: View {
    let host: HostProfile
    let script: String
    let onDone: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @State private var session: TerminalSession?
    @State private var password = ""
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    InstallTerminal(view: session.terminalView)
                        .padding(.horizontal, 6)
                        .modifier(LoginPrompts(session: session, password: $password))
                        .onAppear {
                            session.connect()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { _ = session.terminalView.becomeFirstResponder() }
                        }
                } else if let failure {
                    ContentUnavailableView("Couldn't Start", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .background(Color(uiColor: settings.theme(for: host).editorBackground))
            .navigationTitle("Installing on \(host.name.isEmpty ? host.hostname : host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        session?.disconnect()
                        onDone()
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .pageSizedSheet()
        .task {
            // Its own login: no tmux, no mosh, no reconnecting (that would run the script again).
            var installHost = host
            do {
                installHost.startupCommand = try await ServerCheck.prepare(script, on: host)
            } catch {
                failure = error.localizedDescription
                return
            }
            installHost.useMosh = false
            installHost.autoReconnect = false
            session = TerminalSession(host: installHost, windowSlot: 90, fontSize: settings.fontSize, theme: settings.theme(for: host))
        }
    }
}

private struct InstallTerminal: UIViewRepresentable {
    let view: TerminalView

    func makeUIView(context: Context) -> TerminalView { view }
    func updateUIView(_ uiView: TerminalView, context: Context) {}
}
