import SwiftUI

/// VS Code's Problems for the open file: a toolbar count of errors and warnings, and a list
/// that jumps to each one or hands them all to Claude to fix.
struct ProblemsButton: View {
    let workspace: EditorWorkspace
    let path: String
    let problems: [LanguageServer.Diagnostic]
    let theme: TerminalTheme
    let fontSize: CGFloat
    @State private var showing = false

    var body: some View {
        let shown = problems.filter { $0.severity != .hint }
        let counts = [LanguageServer.Diagnostic.Severity.error, .warning, .information].map { severity in
            (severity, shown.filter { $0.severity == severity }.count)
        }
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                ForEach(counts.filter { $0.1 > 0 }, id: \.0) { severity, number in count(number, severity) }
            }
        }
        .help("Problems")
        .accessibilityLabel("Problems: " + counts.map { "\($0.1) \($0.0)" }.joined(separator: ", "))
        .popover(isPresented: $showing) {
            ProblemsList(workspace: workspace, path: path, problems: shown, theme: theme, fontSize: fontSize)
        }
        #if DEBUG
        .task {
            try? await Task.sleep(for: .seconds(1))
            if CommandLine.arguments.contains("-showProblems") { showing = true }
        }
        #endif
    }

    private func count(_ number: Int, _ severity: LanguageServer.Diagnostic.Severity) -> some View {
        HStack(spacing: 3) {
            Image(systemName: ProblemRow.symbol(for: severity))
                .foregroundStyle(Color(uiColor: theme.problemColor(severity)))
            Text("\(number)").monospacedDigit()
        }
    }
}

struct ProblemsList: View {
    let workspace: EditorWorkspace
    let path: String
    let problems: [LanguageServer.Diagnostic]
    let theme: TerminalTheme
    let fontSize: CGFloat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("PROBLEMS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(workspace.explorer.displayPath(path)).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                        Button {
                            dismiss()
                            let length = problem.endLine == problem.line ? max(problem.endCharacter - problem.character, 1) : 1
                            workspace.reveal(path, line: problem.line + 1, column: problem.character, length: length)
                        } label: {
                            ProblemRow(problem: problem, theme: theme, fontSize: fontSize, showsLocation: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Spacer()
                Button("Fix All with Claude", systemImage: "wand.and.sparkles") {
                    dismiss()
                    workspace.askToFix(problems, in: path)
                }
                .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        // A set width: the list's height is measured at the width it's shown at (wrapped
        // messages came out clipped in a popover free to widen).
        .frame(width: Device.isPhone ? nil : 520)
        .frame(maxHeight: Device.isPhone ? .infinity : nil, alignment: .top)
        .background(Color(uiColor: theme.editorChrome(0.06)))
        .environment(\.colorScheme, theme.isLight ? .light : .dark)
        // iPhone: a sheet (a popover there is narrower than the card).
        .presentationCompactAdaptation(Device.isPhone ? .sheet : .popover)
        .presentationDetents(Device.isPhone ? [.medium, .large] : [.large])
    }
}

/// One problem: its icon, message, and where it came from ("ts(2345)", "shellcheck(SC2086)").
struct ProblemRow: View {
    let problem: LanguageServer.Diagnostic
    let theme: TerminalTheme
    let fontSize: CGFloat
    var showsLocation = false

    static func symbol(for severity: LanguageServer.Diagnostic.Severity) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .hint: "lightbulb"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(for: problem.severity))
                .foregroundStyle(Color(uiColor: theme.problemColor(problem.severity)))
            VStack(alignment: .leading, spacing: 2) {
                Text(problem.message)
                    .font(.system(size: max(fontSize - 1, 11), design: .monospaced))
                    .foregroundStyle(Color(uiColor: theme.editorForeground))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                let location = showsLocation ? "Ln \(problem.line + 1), Col \(problem.character + 1)" : nil
                if let detail = [problem.origin, location].compactMap({ $0 }).joined(separator: "  ·  ").nilIfEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
