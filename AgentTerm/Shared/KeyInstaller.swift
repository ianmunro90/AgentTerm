import Citadel
import Foundation

/// Adds this device's public key to a host's `~/.ssh/authorized_keys` (as `ssh-copy-id` does),
/// over a connection that logs in some other way: a password.
enum KeyInstaller {
    private static let declinedKey = "keyInstall.declined"

    static func install(on host: HostProfile) async throws {
        let line = KeyManager.openSSHPublicKey(for: try KeyManager.loadOrCreate())
        let blob = String(line.split(separator: " ")[1])
        let client = try await TrustedSSH.connect(to: host, timeout: 10)
        defer { Task { try? await client.close() } }
        // The key's base64 and comment hold no quotes, so single quotes are safe.
        let script = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
            + "{ grep -qF '\(blob)' ~/.ssh/authorized_keys || printf '%s\\n' '\(line)' >> ~/.ssh/authorized_keys; } && echo added"
        var output = try await client.executeCommand(script)
        guard (output.readString(length: output.readableBytes) ?? "").contains("added") else {
            throw Failed()
        }
        SSHLogin.setRefusesKey(false, for: host)
    }

    struct Failed: LocalizedError {
        var errorDescription: String? { "~/.ssh/authorized_keys couldn't be updated" }
    }

    /// "Not Now": don't offer again for this host.
    static func decline(for host: HostProfile) {
        let declined = SharedStore.defaults.stringArray(forKey: declinedKey) ?? []
        SharedStore.defaults.set(declined + [host.id.uuidString], forKey: declinedKey)
    }

    static func wasDeclined(for host: HostProfile) -> Bool {
        (SharedStore.defaults.stringArray(forKey: declinedKey) ?? []).contains(host.id.uuidString)
    }
}

/// Asks for a host's password while logging in.
struct PasswordRequest: Identifiable {
    let id = UUID()
    /// The last one was wrong.
    let retry: Bool
    /// The password (nil: cancelled), and whether to save it in the Keychain.
    let respond: (String?, Bool) -> Void
}
