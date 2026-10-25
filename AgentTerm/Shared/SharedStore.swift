import Foundation

/// Storage shared by the app and its Share extension through the App Group: hosts, trusted host
/// keys and the lock settings live in the group's defaults, the SSH key in the group's Keychain.
enum SharedStore {
    /// group.<prefix>.agentterm, from this bundle's identifier (<prefix>.agentterm, or
    /// <prefix>.agentterm.share for the extension), so builds under other prefixes work.
    static let appGroup: String = {
        var base = Bundle.main.bundleIdentifier ?? "com.example.agentterm"
        if base.hasSuffix(".share") { base.removeLast(".share".count) }
        return "group." + base
    }()

    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    /// Keys that moved from the app's own defaults when the Share extension arrived (1.2).
    private static let sharedKeys = ["hosts.v1", "knownHosts.v1"]

    /// One-time copy of the app's earlier, unshared defaults. Safe to call on every launch.
    static func migrateFromStandardDefaults() {
        let standard = UserDefaults.standard
        for key in sharedKeys where defaults.object(forKey: key) == nil {
            if let value = standard.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }
}
