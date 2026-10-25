import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// Trust-on-first-use host key table, stored as OpenSSH public key strings keyed by endpoint.
enum KnownHosts {
    private static let defaultsKey = "knownHosts.v1"

    static func key(for endpoint: String) -> String? {
        all[endpoint]
    }

    static func set(_ key: String, for endpoint: String) {
        var table = all
        table[endpoint] = key
        SharedStore.defaults.set(table, forKey: defaultsKey)
    }

    static func forget(_ endpoint: String) {
        var table = all
        table[endpoint] = nil
        SharedStore.defaults.set(table, forKey: defaultsKey)
    }

    private static var all: [String: String] {
        SharedStore.defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    /// `ED25519 SHA256:…`, as printed by `ssh-keygen -lf`.
    static func fingerprint(_ openSSHKey: String) -> String {
        let fields = openSSHKey.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return openSSHKey }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let type = fields[0].replacingOccurrences(of: "ssh-", with: "").uppercased()
        return "\(type) SHA256:\(digest)"
    }
}

/// What the user is asked when a host key is new or has changed.
struct HostKeyChallenge: Identifiable {
    let id = UUID()
    let endpoint: String
    let presentedKey: String
    let knownKey: String?
    let respond: (Bool) -> Void

    var isMismatch: Bool { knownKey != nil }
}

struct HostKeyRejected: LocalizedError {
    let changed: Bool
    var errorDescription: String? {
        changed ? "Host key changed — connection refused." : "Host key not trusted."
    }
}

/// Accepts the known key silently; otherwise asks the user via `ask`.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: String
    private let ask: @Sendable (HostKeyChallenge.Partial) async -> Bool

    init(endpoint: String, ask: @escaping @Sendable (HostKeyChallenge.Partial) async -> Bool) {
        self.endpoint = endpoint
        self.ask = ask
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        let known = KnownHosts.key(for: endpoint)
        if known == presented {
            validationCompletePromise.succeed(())
            return
        }
        let endpoint = self.endpoint
        let ask = self.ask
        Task {
            if await ask(.init(endpoint: endpoint, presentedKey: presented, knownKey: known)) {
                KnownHosts.set(presented, for: endpoint)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyRejected(changed: known != nil))
            }
        }
    }
}

extension HostKeyChallenge {
    struct Partial: Sendable {
        let endpoint: String
        let presentedKey: String
        let knownKey: String?
    }
}
