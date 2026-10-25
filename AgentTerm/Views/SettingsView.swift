import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var lock: AppLock
    @Environment(\.dismiss) private var dismiss
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(TerminalTheme.all) { theme in
                        Button {
                            settings.defaultThemeID = theme.id
                        } label: {
                            HStack(spacing: 12) {
                                ThemePreview(theme: theme)
                                Text(theme.name).foregroundStyle(.primary)
                                Spacer()
                                if settings.defaultThemeID == theme.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Default theme")
                } footer: {
                    Text("Hosts can override this in Edit Host → Appearance.")
                }

                Section {
                    Toggle("Require \(LockSettings.methodName)", isOn: $lock.isEnabled)
                    if lock.isEnabled {
                        Picker("Lock After", selection: $lock.grace) {
                            Text("Immediately").tag(TimeInterval(0))
                            Text("1 Minute").tag(TimeInterval(60))
                            Text("5 Minutes").tag(TimeInterval(300))
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text("Locks AgentTerm when you leave it, and the Share extension asks too. Connections keep running while locked.")
                }

                Section {
                    Toggle("Hide sidebar when connected", isOn: $settings.autoHideSidebar)
                } footer: {
                    Text("Bring it back with the sidebar button at the top left.")
                }

                Section("Text") {
                    Stepper(value: $settings.fontSize, in: 9...28, step: 1) {
                        Text("Size \(Int(settings.fontSize)) pt")
                    }
                }

                Section {
                    Button("About AgentTerm") { showingAbout = true }
                }
            }
            .navigationDestination(isPresented: $showingAbout) { AboutView() }
            .hidesTerminalKeyboard()
            #if DEBUG
            .onAppear { if CommandLine.arguments.contains("-showAbout") { showingAbout = true } }
            #endif
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// A tiny prompt-and-swatches preview of a theme.
private struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("~ $")
                .font(.caption.monospaced())
                .foregroundStyle(Color(uiColor: UIColor(hex: theme.foreground)))
            HStack(spacing: 2) {
                ForEach(Array(theme.swatch.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
                }
            }
        }
        .padding(6)
        .frame(width: 70, alignment: .leading)
        .background(theme.backgroundColor, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12)))
    }
}
