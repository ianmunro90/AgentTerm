import CryptoKit
import Foundation
import Security
import UIKit
import Citadel

/// Owns the device's SSH identity: one Ed25519 key kept in the Keychain (this device only), in
/// the App Group's access group so the Share extension can use it too.
enum KeyManager {
    // A fixed label, whatever the bundle prefix (items are scoped by the App Group
    // anyway): changing it would orphan the key and passwords existing installs saved.
    private static let service = "com.mudhoax.agentterm"
    private static let account = "ssh-ed25519"
    /// "agentterm@iphone", "agentterm@ipad": how the key reads in authorized_keys.
    static let comment = "agentterm@" + UIDevice.current.model.lowercased().replacingOccurrences(of: " ", with: "")

    enum KeyError: LocalizedError {
        case keychain(OSStatus)
        case unsupportedKey
        case rsaKey
        case needsPassphrase
        case wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            case .unsupportedKey:
                return "Only OpenSSH Ed25519 private keys (“-----BEGIN OPENSSH PRIVATE KEY-----”, from `ssh-keygen -t ed25519`) can be imported."
            case .rsaKey:
                return "RSA keys aren't supported: AgentTerm can only sign with them the old way (ssh-rsa, SHA-1), which current OpenSSH servers refuse. Use an Ed25519 key (`ssh-keygen -t ed25519`)."
            case .needsPassphrase:
                return "This key is protected by a passphrase: enter it to import the key."
            case .wrongPassphrase:
                return "Wrong passphrase."
            }
        }
    }

    /// Returns the stored key, generating one on first use.
    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let key = try load() { return key }
        let key = Curve25519.Signing.PrivateKey()
        try store(key)
        return key
    }

    static func load() throws -> Curve25519.Signing.PrivateKey? {
        if let key = try load(query: baseQuery) { return key }
        // Before 1.2 the key lived in the app's private access group; move it to the shared one
        // so this device keeps the key its hosts already trust.
        var legacy = baseQuery
        legacy[kSecAttrAccessGroup as String] = nil
        guard let key = try load(query: legacy) else { return nil }
        SecItemDelete(legacy as CFDictionary)
        try store(key)
        return key
    }

    private static func load(query base: [String: Any]) throws -> Curve25519.Signing.PrivateKey? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeyError.keychain(status) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// Replaces the stored key with a freshly generated one.
    @discardableResult
    static func regenerate() throws -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        try store(key)
        return key
    }

    /// Replaces the stored key with an OpenSSH-format Ed25519 private key (`-----BEGIN OPENSSH
    /// PRIVATE KEY-----`), decrypting it with `passphrase` if it has one. It's stored decrypted,
    /// in this device's Keychain, as a generated key is.
    static func importOpenSSH(_ text: String, passphrase: String = "") throws {
        try store(parseOpenSSH(text, passphrase: passphrase))
    }

    static func parseOpenSSH(_ text: String, passphrase: String = "") throws -> Curve25519.Signing.PrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let type = try? SSHKeyDetection.detectPrivateKeyType(from: trimmed), type != .ed25519 {
            throw type == .rsa ? KeyError.rsaKey : KeyError.unsupportedKey
        }
        let encrypted = isEncrypted(trimmed)
        if encrypted, passphrase.isEmpty { throw KeyError.needsPassphrase }
        guard let key = try? Curve25519.Signing.PrivateKey(sshEd25519: trimmed, decryptionKey: encrypted ? Data(passphrase.utf8) : nil) else {
            throw encrypted ? KeyError.wrongPassphrase : KeyError.unsupportedKey
        }
        return key
    }

    /// An OpenSSH private key names its cipher near the start: "none" unless it's encrypted.
    private static func isEncrypted(_ text: String) -> Bool {
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let data = Data(base64Encoded: body) else { return false }
        return Data(data.prefix(64)).range(of: Data("none".utf8)) == nil
    }

    /// `ssh-ed25519 AAAA… agentterm@ipad`, ready for authorized_keys.
    static func openSSHPublicKey(for key: Curve25519.Signing.PrivateKey) -> String {
        var blob = Data()
        blob.appendSSHString(Data("ssh-ed25519".utf8))
        blob.appendSSHString(key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: SharedStore.appGroup,
        ]
    }

    private static func store(_ key: Curve25519.Signing.PrivateKey) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.keychain(status) }
    }
}

extension Data {
    /// Appends an SSH wire-format string (uint32 big-endian length + bytes).
    mutating func appendSSHString(_ bytes: Data) {
        var length = UInt32(bytes.count).bigEndian
        append(Data(bytes: &length, count: 4))
        append(bytes)
    }
}
