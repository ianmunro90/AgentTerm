import Foundation
import Security

/// Hosts' login passwords: saved in the App Group's Keychain (this device only, so the Share
/// extension can log in too), or remembered only until the app quits.
enum Passwords {
    // A fixed label, whatever the bundle prefix (items are scoped by the App Group
    // anyway): changing it would orphan the key and passwords existing installs saved.
    private static let service = "com.mudhoax.agentterm.password"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var remembered: [UUID: String] = [:]

    /// The saved password, else one remembered from earlier in this run of the app.
    static func password(for host: HostProfile) -> String? {
        if let saved = saved(for: host) { return saved }
        lock.lock()
        defer { lock.unlock() }
        return remembered[host.id]
    }

    static func saved(for host: HostProfile) -> String? {
        var query = query(for: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `password` in the Keychain (nil or empty removes it).
    static func save(_ password: String?, for host: HostProfile) {
        SecItemDelete(query(for: host) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var attributes = query(for: host)
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Keeps `password` for this run of the app only (background connections use it too).
    static func remember(_ password: String, for host: HostProfile) {
        lock.lock()
        defer { lock.unlock() }
        remembered[host.id] = password
    }

    /// Forgets the saved and remembered password (a host deleted, or the password removed).
    static func forget(_ host: HostProfile) {
        save(nil, for: host)
        lock.lock()
        defer { lock.unlock() }
        remembered[host.id] = nil
    }

    private static func query(for host: HostProfile) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.id.uuidString,
            kSecAttrAccessGroup as String: SharedStore.appGroup,
        ]
    }
}
