import Citadel
import Foundation

/// SSH connections made in the background (tmux sidebar, uploads, the editor, the Share
/// extension). They never prompt: only a host key that's already trusted is accepted, and only
/// this device's key or a saved or remembered password logs in.
enum TrustedSSH {
    struct HostNotTrusted: LocalizedError {
        var errorDescription: String? { "Connect once in AgentTerm to trust this host's key first." }
    }

    static func connect(to host: HostProfile, timeout: Int64 = 5) async throws -> SSHClient {
        guard KnownHosts.key(for: host.endpoint) != nil else { throw HostNotTrusted() }
        let validator = TOFUHostKeyValidator(endpoint: host.endpoint) { _ in false }
        return try await SSHLogin.connect(to: host, validator: validator, timeout: timeout).0
    }
}
