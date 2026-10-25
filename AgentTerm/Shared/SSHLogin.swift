import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// Logs in as OpenSSH does: this device's key first, then a password if the server takes one
/// (the saved or remembered one, else asked for when `ask` is given; three tries). Citadel
/// gives a connection one login method, so each is its own connection. Keyboard-interactive
/// (one-time codes) isn't available: swift-nio-ssh doesn't implement it.
enum SSHLogin {
    struct Failed: LocalizedError {
        let triedPassword: Bool
        let serverTakesPasswords: Bool

        var errorDescription: String? {
            if triedPassword { return "password not accepted" }
            if serverTakesPasswords { return "this device's key wasn't accepted, and no password was given" }
            return "this device's key wasn't accepted (the server doesn't allow passwords): add its public key to ~/.ssh/authorized_keys"
        }
    }

    /// A connection, and the password it logged in with (nil: the key). Background connections
    /// (no `ask`) to a host known to refuse the key go straight to the password, or aren't
    /// tried at all without one: every failed login counts against this device in OpenSSH's
    /// penalties (and fail2ban). Interactive ones try the key first, in case it was added since.
    static func connect(to host: HostProfile, validator: TOFUHostKeyValidator, timeout: Int64,
                        ask: (@Sendable (_ retry: Bool) async -> String?)? = nil) async throws -> (SSHClient, password: String?) {
        var password = Passwords.password(for: host)
        var serverTakesPasswords = true
        let skipKey = ask == nil && refusesKey(host)
        if skipKey, password == nil { throw Failed(triedPassword: false, serverTakesPasswords: true) }
        if !skipKey {
            let probe = KeyOffer(username: host.username, key: try KeyManager.loadOrCreate())
            do {
                let client = try await connect(host, .custom(probe), validator, timeout)
                if refusesKey(host) { setRefusesKey(false, for: host) }
                return (client, nil)
            } catch where isLoginFailure(error) {
                // The key wasn't taken: a password, if the server takes them.
                serverTakesPasswords = probe.serverTakesPasswords
                setRefusesKey(true, for: host)
            }
        }
        var tries = 0
        while tries < 3 {
            if password == nil, let ask { password = await ask(tries > 0) }
            guard let attempt = password, serverTakesPasswords else { break }
            tries += 1
            do {
                return (try await connect(host, .passwordBased(username: host.username, password: attempt), validator, timeout), attempt)
            } catch where isLoginFailure(error) {
                password = nil
                if ask == nil { break }
            }
        }
        throw Failed(triedPassword: tries > 0, serverTakesPasswords: serverTakesPasswords)
    }

    private static let refusedKey = "login.keyRefused"

    /// The host refused this device's key last time (until the key is added to it).
    static func refusesKey(_ host: HostProfile) -> Bool {
        (SharedStore.defaults.stringArray(forKey: refusedKey) ?? []).contains(host.id.uuidString)
    }

    static func setRefusesKey(_ refuses: Bool, for host: HostProfile) {
        var hosts = Set(SharedStore.defaults.stringArray(forKey: refusedKey) ?? [])
        if refuses { hosts.insert(host.id.uuidString) } else { hosts.remove(host.id.uuidString) }
        SharedStore.defaults.set(Array(hosts), forKey: refusedKey)
    }

    private static func connect(_ host: HostProfile, _ method: SSHAuthenticationMethod,
                                _ validator: TOFUHostKeyValidator, _ timeout: Int64) async throws -> SSHClient {
        try await SSHClient.connect(
            host: host.hostname,
            port: host.port,
            authenticationMethod: method,
            hostKeyValidator: .custom(validator),
            reconnect: .never,
            connectTimeout: .seconds(timeout)
        )
    }

    private static func isLoginFailure(_ error: Error) -> Bool {
        if error is KeyOffer.NotTaken { return true }
        if let error = error as? SSHClientError {
            switch error {
            case .allAuthenticationOptionsFailed, .unsupportedPrivateKeyAuthentication, .unsupportedPasswordAuthentication: return true
            default: return false
            }
        }
        return false
    }
}

/// Offers this device's key, noting whether the server would take a password instead.
private final class KeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    struct NotTaken: Error {}

    private let username: String
    private let key: Curve25519.Signing.PrivateKey
    private(set) var serverTakesPasswords = false

    init(username: String, key: Curve25519.Signing.PrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        serverTakesPasswords = availableMethods.contains(.password)
        guard availableMethods.contains(.publicKey) else { return nextChallengePromise.fail(NotTaken()) }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
    }
}
