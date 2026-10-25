import Foundation
import LocalAuthentication

/// The app lock's settings (shared so the Share extension honours them) and the check itself.
enum LockSettings {
    private static let enabledKey = "lock.enabled"
    private static let graceKey = "lock.grace"

    /// On by default.
    static var isEnabled: Bool {
        // Off until turned on (Settings, or the setup guide): a first launch shouldn't open on a
        // passcode prompt.
        get { SharedStore.defaults.object(forKey: enabledKey) as? Bool ?? false }
        set { SharedStore.defaults.set(newValue, forKey: enabledKey) }
    }

    /// How long the app may be away before it locks again.
    static var grace: TimeInterval {
        get { SharedStore.defaults.object(forKey: graceKey) as? Double ?? 60 }
        set { SharedStore.defaults.set(newValue, forKey: graceKey) }
    }

    /// "Face ID", "Touch ID", "Optic ID" or "Passcode".
    static var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// Face ID with the device passcode as fallback. True if the person was verified.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: there's nothing to check against.
            return error?.code == LAError.passcodeNotSet.rawValue
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
