import SwiftUI

/// Searchable snippet picker shown from the terminal toolbar.
struct SnippetsView: View {
    let onSend: (Snippet, _ pressReturn: Bool) -> Void
    @EnvironmentObject private var store: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editing: Snippet?

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredSections, id: \.category) { section in
                    Section(section.category) {
                        ForEach(section.snippets) { snippet in
                            Button {
                                send(snippet, pressReturn: snippet.pressReturn)
                            } label: {
                                SnippetRow(snippet: snippet)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: snippet) }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Snippets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A sheet on iPhone (a popover on iPad, closed by tapping outside).
                if Device.isPhone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Snippet", systemImage: "plus") {
                        editing = Snippet(title: "", text: "", category: Snippet.customCategory, pressReturn: true)
                    }
                }
            }
            .sheet(item: $editing) { snippet in
                SnippetEditorView(snippet: snippet)
            }
        }
    }

    private var filteredSections: [(category: String, snippets: [Snippet])] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.sections }
        return store.sections.compactMap { section in
            let matches = section.snippets.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query)
                    || section.category.localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : (section.category, matches)
        }
    }

    @ViewBuilder
    private func menu(for snippet: Snippet) -> some View {
        Button("Run", systemImage: "return") { send(snippet, pressReturn: true) }
        Button("Insert Without Return", systemImage: "text.insert") { send(snippet, pressReturn: false) }
        if snippet.display == nil {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = snippet.text }
        }
        if store.isCustom(snippet) {
            Button("Edit", systemImage: "pencil") { editing = snippet }
            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(snippet) }
        } else {
            Button("Add to My Snippets", systemImage: "star") {
                var copy = snippet
                copy.id = UUID()
                store.upsert(copy)
            }
        }
    }

    private func send(_ snippet: Snippet, pressReturn: Bool) {
        onSend(snippet, pressReturn)
        dismiss()
    }
}

private struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.title)
                Text(snippet.preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: snippet.display != nil ? "keyboard" : snippet.pressReturn ? "return" : "text.cursor")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct SnippetEditorView: View {
    @EnvironmentObject private var store: SnippetStore
    @Environment(\.dismiss) private var dismiss
    @State private var snippet: Snippet

    init(snippet: Snippet) {
        _snippet = State(initialValue: snippet)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $snippet.title)
                }
                Section {
                    TextEditor(text: $snippet.text)
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Text")
                } footer: {
                    Text("Several lines are sent as one paste when the program supports it (Claude Code, bash).")
                }
                Section {
                    Toggle("Press Return after", isOn: $snippet.pressReturn)
                }
            }
            .navigationTitle(store.isCustom(snippet) ? "Edit Snippet" : "New Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if snippet.title.trimmingCharacters(in: .whitespaces).isEmpty {
                            snippet.title = String(snippet.text.prefix(40))
                        }
                        store.upsert(snippet)
                        dismiss()
                    }
                    .disabled(snippet.text.isEmpty)
                }
            }
        }
    }
}
