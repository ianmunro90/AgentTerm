import SwiftUI
import UIKit

/// Locks AgentTerm behind Face ID (passcode fallback) after it has been away longer than the
/// grace period. The lock screen is a window of its own above everything in each scene, so open
/// sheets and popovers are covered too, and it goes up as the app leaves the screen so the app
/// switcher's snapshot never shows a terminal.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false

    @Published var isEnabled: Bool {
        didSet {
            LockSettings.isEnabled = isEnabled
            if !isEnabled { isLocked = false }
            updateWindows()
        }
    }

    @Published var grace: TimeInterval {
        didSet { LockSettings.grace = grace }
    }

    /// Covers the app while it's off screen, locked or not.
    private var isCovered = false
    private var backgroundedAt: Date?
    /// Prompt automatically only when coming back to the app, not after a cancelled prompt
    /// (the Face ID sheet itself makes the app inactive and active again).
    private var promptOnActivate = true
    private var windows: [ObjectIdentifier: UIWindow] = [:]

    init() {
        #if DEBUG
        // Simulator runs can't answer the passcode prompt.
        if CommandLine.arguments.contains("-noLock") { LockSettings.isEnabled = false }
        #endif
        isEnabled = LockSettings.isEnabled
        grace = LockSettings.grace
        isLocked = LockSettings.isEnabled

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didBecomeActive() }
        }
        center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWindows() }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            MainActor.assumeIsolated { _ = self?.windows.removeValue(forKey: ObjectIdentifier(scene)) }
        }
    }

    func unlock() {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let verified = await LockSettings.authenticate(reason: "Unlock AgentTerm to use your terminals.")
            isAuthenticating = false
            if verified {
                isLocked = false
                updateWindows()
            }
        }
    }

    // MARK: App lifecycle

    private func didEnterBackground() {
        backgroundedAt = Date()
        isCovered = true
        updateWindows()
    }

    private func willEnterForeground() {
        promptOnActivate = true
        guard isEnabled else { return }
        if let since = backgroundedAt, Date().timeIntervalSince(since) >= grace {
            isLocked = true
            // Keep keystrokes (hardware keyboard included) away from the terminal while locked.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        updateWindows()
    }

    private func didBecomeActive() {
        isCovered = false
        updateWindows()
        if isLocked, promptOnActivate {
            promptOnActivate = false
            unlock()
        }
    }

    // MARK: Lock windows

    private func updateWindows() {
        let show = isCovered || (isEnabled && isLocked)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            let window = windows[ObjectIdentifier(scene)] ?? makeWindow(for: scene)
            window.isHidden = !show
        }
    }

    private func makeWindow(for scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockScreen(lock: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        windows[ObjectIdentifier(scene)] = window
        return window
    }
}

private struct LockScreen: View {
    @ObservedObject var lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: lock.isLocked ? "lock.fill" : "terminal")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("AgentTerm")
                    .font(.title2.weight(.semibold))
                if lock.isLocked {
                    Button {
                        lock.unlock()
                    } label: {
                        Label("Unlock with \(LockSettings.methodName)", systemImage: "faceid")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(lock.isAuthenticating)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
