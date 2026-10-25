import Foundation

/// A piece of text (or key sequence) typed into the terminal.
struct Snippet: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var category: String
    /// Press Return after typing. Off for commands meant to be completed, and for keys.
    var pressReturn: Bool
    /// How keys are shown (e.g. "⌃B c"); nil shows the text itself.
    var display: String?

    var preview: String { display ?? text }

    static let customCategory = "My Snippets"
}

/// Built-in snippets plus the user's own, which are stored in UserDefaults.
@MainActor
final class SnippetStore: ObservableObject {
    @Published var custom: [Snippet] {
        didSet {
            if let data = try? JSONEncoder().encode(custom) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    private static let defaultsKey = "snippets.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Snippet].self, from: data) {
            custom = saved
        } else {
            custom = []
        }
    }

    /// Categories in display order, each with its snippets.
    var sections: [(category: String, snippets: [Snippet])] {
        var result: [(String, [Snippet])] = []
        if !custom.isEmpty { result.append((Snippet.customCategory, custom)) }
        for category in Self.builtInOrder {
            result.append((category, Self.builtIns.filter { $0.category == category }))
        }
        return result
    }

    func upsert(_ snippet: Snippet) {
        var snippet = snippet
        snippet.category = Snippet.customCategory
        if let index = custom.firstIndex(where: { $0.id == snippet.id }) {
            custom[index] = snippet
        } else {
            custom.append(snippet)
        }
    }

    func delete(_ snippet: Snippet) {
        custom.removeAll { $0.id == snippet.id }
    }

    func isCustom(_ snippet: Snippet) -> Bool {
        custom.contains { $0.id == snippet.id }
    }

    // MARK: Built-ins

    private static let builtInOrder = ["Keys", "Claude Code", "tmux", "Git", "Docker", "System"]

    private static func run(_ category: String, _ title: String, _ text: String) -> Snippet {
        Snippet(title: title, text: text, category: category, pressReturn: true)
    }

    private static func insert(_ category: String, _ title: String, _ text: String) -> Snippet {
        Snippet(title: title, text: text, category: category, pressReturn: false)
    }

    private static func key(_ category: String, _ title: String, _ text: String, _ display: String) -> Snippet {
        Snippet(title: title, text: text, category: category, pressReturn: false, display: display)
    }

    /// tmux's default prefix, Ctrl-B (a ~/.tmux.conf may change it).
    private static let tmuxPrefix = "\u{02}"

    static let builtIns: [Snippet] = [
        key("Keys", "Interrupt", "\u{03}", "⌃C"),
        key("Keys", "End of input / exit", "\u{04}", "⌃D"),
        key("Keys", "Suspend", "\u{1A}", "⌃Z"),
        key("Keys", "Clear screen", "\u{0C}", "⌃L"),
        key("Keys", "Search history", "\u{12}", "⌃R"),
        key("Keys", "Escape", "\u{1B}", "⎋"),
        key("Keys", "Tab", "\t", "⇥"),

        run("Claude Code", "Start Claude Code", "claude"),
        run("Claude Code", "Continue last conversation", "claude --continue"),
        run("Claude Code", "Pick a conversation to resume", "claude --resume"),
        key("Claude Code", "Cycle mode", "\u{1B}[Z", "⇧⇥  (Shift+Tab)"),
        key("Claude Code", "Rewind", "\u{1B}\u{1B}", "⎋ ⎋  (Esc Esc)"),
        run("Claude Code", "Clear conversation", "/clear"),
        run("Claude Code", "Compact conversation", "/compact"),
        run("Claude Code", "Choose model", "/model"),
        run("Claude Code", "Help", "/help"),

        key("tmux", "New window", tmuxPrefix + "c", "⌃B c"),
        key("tmux", "Next window", tmuxPrefix + "n", "⌃B n"),
        key("tmux", "Previous window", tmuxPrefix + "p", "⌃B p"),
        key("tmux", "Choose window or session", tmuxPrefix + "w", "⌃B w"),
        key("tmux", "Split side by side", tmuxPrefix + "%", "⌃B %"),
        key("tmux", "Split top and bottom", tmuxPrefix + "\"", "⌃B \""),
        key("tmux", "Next pane", tmuxPrefix + "o", "⌃B o"),
        key("tmux", "Zoom pane", tmuxPrefix + "z", "⌃B z"),
        key("tmux", "Scroll back (q to exit)", tmuxPrefix + "[", "⌃B ["),
        key("tmux", "Rename window", tmuxPrefix + ",", "⌃B ,"),
        key("tmux", "Close pane (asks y/n)", tmuxPrefix + "x", "⌃B x"),
        key("tmux", "Detach", tmuxPrefix + "d", "⌃B d"),
        run("tmux", "List sessions", "tmux ls"),


        run("Git", "Status", "git status -sb"),
        run("Git", "Recent history", "git log --oneline --graph -20"),
        run("Git", "What changed", "git diff --stat"),
        run("Git", "Pull (rebase)", "git pull --rebase"),
        run("Git", "Push", "git push"),
        run("Git", "Back to previous branch", "git switch -"),
        insert("Git", "Clone…", "git clone "),

        run("Docker", "Running containers", "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"),
        run("Docker", "Compose status", "docker compose ps"),
        insert("Docker", "Follow compose logs…", "docker compose logs -f --tail=100 "),
        run("Docker", "Compose up", "docker compose up -d"),
        run("Docker", "Pull and restart", "docker compose pull && docker compose up -d"),
        run("Docker", "Disk usage", "docker system df"),

        run("System", "Processes", "htop"),
        run("System", "Disk space", "df -h -x tmpfs -x devtmpfs"),
        run("System", "Memory", "free -h"),
        run("System", "Biggest here", "du -sh * .[!.]* 2>/dev/null | sort -h | tail -15"),
        run("System", "Follow system log", "journalctl -f"),
        run("System", "Network addresses", "ip -br a"),
        insert("System", "Service status…", "systemctl status "),
        insert("System", "Follow a file…", "tail -f "),
    ]
}
