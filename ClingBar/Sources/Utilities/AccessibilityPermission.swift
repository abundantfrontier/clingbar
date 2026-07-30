import ApplicationServices
import AppKit

enum AccessibilityPermission {
    private static let didOfferSettingsKey = "clingbar.didOfferAccessibilitySettings"

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Check only — does **not** show UI or change frontmost app.
    static func checkTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Launch-time handling for LSUIElement apps.
    ///
    /// - If already trusted → do nothing (never open Settings).
    /// - If not trusted → open Settings **at most once** so rebuilds / delayed trust
    ///   checks don’t nag on every launch. Menu item can always re-open Settings.
    static func scheduleLaunchPromptIfNeeded() {
        // Immediate bail if already trusted.
        if checkTrusted() { return }

        // Give TCC a moment; trust can lag right after launch on some OS builds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if checkTrusted() { return }

            // Already sent the user to Settings once — stop auto-opening.
            if UserDefaults.standard.bool(forKey: didOfferSettingsKey) {
                NSLog("ClingBar: Accessibility still not trusted; not re-opening Settings (use menu to open)")
                return
            }

            UserDefaults.standard.set(true, forKey: didOfferSettingsKey)
            openSystemSettings()
        }
    }

    /// Menu: “Request Accessibility…” — always available.
    static func promptIfNeeded() {
        if checkTrusted() {
            // Already on; still open Settings so user can confirm the toggle.
            openSystemSettings()
            return
        }
        // Prefer Settings (clean menu bar) over the system AX sheet for accessory apps.
        UserDefaults.standard.set(true, forKey: didOfferSettingsKey)
        openSystemSettings()
        // Also request the official trust prompt when possible (some OS versions honor both).
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ]
        for urlString in urls {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
