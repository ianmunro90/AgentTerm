import Foundation

/// A saved SSH destination.
struct HostProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var hostname: String
    var port: Int = 22
    var username: String
    /// Typed into the shell right after login, e.g. to attach to a tmux session.
    /// `{window}` becomes "" in the first window and "-2", "-3", … in the others.
    var startupCommand: String = ""
    /// Reconnect automatically when the app returns to the foreground.
    var autoReconnect: Bool = true
    /// Log in over SSH only to start `mosh-server`, then talk mosh over UDP.
    var useMosh: Bool = false
    /// nil follows the app's default theme.
    var themeID: String?
    /// Where dropped, pasted and shared files go: relative to the home folder, or absolute.
    var uploadDirectory: String = "uploads"

    /// Key used for the known-hosts table.
    var endpoint: String { port == 22 ? hostname : "[\(hostname)]:\(port)" }

    func startupCommand(window slot: Int) -> String {
        startupCommand.replacingOccurrences(of: "{window}", with: slot <= 1 ? "" : "-\(slot)")
    }

    /// The startup command that keeps a session alive in tmux, one session per window.
    static let tmuxStartupCommand = "tmux new -A -s main{window}"

    init(name: String, hostname: String, username: String, startupCommand: String = "") {
        self.name = name
        self.hostname = hostname
        self.username = username
        self.startupCommand = startupCommand
    }

    // Tolerates hosts saved before newer fields existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        hostname = try c.decode(String.self, forKey: .hostname)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try c.decode(String.self, forKey: .username)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        useMosh = try c.decodeIfPresent(Bool.self, forKey: .useMosh) ?? false
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID)
        uploadDirectory = try c.decodeIfPresent(String.self, forKey: .uploadDirectory) ?? "uploads"
    }
}

/// Persists host profiles in UserDefaults. A first launch starts with none.
@MainActor
final class HostStore: ObservableObject {
    @Published var hosts: [HostProfile] {
        didSet { save() }
    }

    private static let defaultsKey = "hosts.v1"

    init() {
        if let data = SharedStore.defaults.data(forKey: Self.defaultsKey),
           var saved = try? JSONDecoder().decode([HostProfile].self, from: data) {
            // 1.0's preset attached every window to the same tmux session.
            for index in saved.indices where saved[index].startupCommand == "tmux new -A -s main" {
                saved[index].startupCommand = HostProfile.tmuxStartupCommand
            }
            hosts = saved
        } else {
            hosts = []
        }
        #if DEBUG
        // A first launch, for the setup flow: no hosts.
        if CommandLine.arguments.contains("-resetHosts") { hosts = [] }
        // -testHost user@host:port: add (once) and use a host.
        if let index = CommandLine.arguments.firstIndex(of: "-testHost"), CommandLine.arguments.indices.contains(index + 1) {
            let spec = CommandLine.arguments[index + 1]
            let user = String(spec.prefix { $0 != "@" })
            let rest = spec.dropFirst(user.count + 1)
            let name = String(rest.prefix { $0 != ":" })
            var host = HostProfile(name: "Test", hostname: name, username: user)
            if let n = CommandLine.arguments.firstIndex(of: "-testName"), CommandLine.arguments.indices.contains(n + 1) {
                host.name = CommandLine.arguments[n + 1]
            }
            host.port = Int(rest.dropFirst(name.count + 1)) ?? 22
            host.useMosh = CommandLine.arguments.contains("-testMosh")
            if let s = CommandLine.arguments.firstIndex(of: "-testStartup"), CommandLine.arguments.indices.contains(s + 1) {
                host.startupCommand = CommandLine.arguments[s + 1]
            }
            if !hosts.contains(where: { $0.hostname == host.hostname && $0.port == host.port && $0.username == host.username }) {
                hosts.append(host)
            }
        }
        #endif
    }

    func upsert(_ host: HostProfile) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    func delete(_ host: HostProfile) {
        hosts.removeAll { $0.id == host.id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) {
            SharedStore.defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Hands out window numbers (1, 2, 3, …) so each window gets its own `{window}` tmux session.
@MainActor
final class WindowRegistry: ObservableObject {
    private var inUse = Set<Int>()

    /// Keeps `preferred` (a restored window's old number) when it's free, else the lowest free number.
    func claim(preferred: Int) -> Int {
        if preferred > 0, !inUse.contains(preferred) {
            inUse.insert(preferred)
            return preferred
        }
        var slot = 1
        while inUse.contains(slot) { slot += 1 }
        inUse.insert(slot)
        return slot
    }

    func release(_ slot: Int) {
        inUse.remove(slot)
    }
}
