import Foundation

/// Focus-bar app pin. Primary click always stays on the current Space.
struct PinnedApp: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var displayName: String

    init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    // Tolerate older settings that included activationPolicy.
    enum CodingKeys: String, CodingKey {
        case bundleIdentifier, displayName, activationPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        displayName = try c.decode(String.self, forKey: .displayName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encode(displayName, forKey: .displayName)
    }
}

enum DefaultPinnedApps {
    static let all: [PinnedApp] = [
        PinnedApp(bundleIdentifier: "com.microsoft.VSCode", displayName: "VS Code"),
        PinnedApp(bundleIdentifier: "com.todesktop.230313mzl4w4u92", displayName: "Cursor"),
        PinnedApp(bundleIdentifier: "com.apple.finder", displayName: "Finder"),
        PinnedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
        PinnedApp(bundleIdentifier: "com.googlecode.iterm2", displayName: "iTerm"),
        PinnedApp(bundleIdentifier: "dev.warp.Warp-Stable", displayName: "Warp"),
        PinnedApp(bundleIdentifier: "com.apple.Safari", displayName: "Safari"),
        PinnedApp(bundleIdentifier: "com.google.Chrome", displayName: "Chrome"),
        PinnedApp(bundleIdentifier: "company.thebrowser.Browser", displayName: "Arc"),
        PinnedApp(bundleIdentifier: "com.brave.Browser", displayName: "Brave"),
    ]
}

/// Focus-bar visibility for pinned apps that are running elsewhere.
///
/// Pin **settings** stay put. We only hide the **slot** when a click would be a
/// dead stay-here action: app is running, has no window on this Space, and we
/// cannot open another window here (Stocks / Settings / …).
/// Multi-window apps (Terminal, browsers, editors) stay visible so “open here” works.
enum FocusBarVisibility {
    /// Apps we can reliably open another window for on the current Space.
    static let multiWindowIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// Whether this pin should appear on the Focus bar for the current Space.
    static func shouldShowPin(
        bundleIdentifier: String,
        isRunning: Bool,
        hasWindowOnCurrentSpace: Bool
    ) -> Bool {
        if hasWindowOnCurrentSpace { return true }
        if !isRunning { return true } // launch on this Space
        // Running, but only (or effectively only) on another Space.
        if canOpenAnotherWindowHere(bundleIdentifier) { return true }
        return false
    }

    static func canOpenAnotherWindowHere(_ bundleIdentifier: String) -> Bool {
        if multiWindowIDs.contains(bundleIdentifier) { return true }
        if JumpAppPolicy.isBrowser(bundleIdentifier) { return true }
        // Known single-destination utilities (Stocks, Calculator, …).
        if JumpAppPolicy.alwaysJump(bundleIdentifier) { return false }
        // Unknown apps: keep visible and let activate try “new window here”.
        return true
    }
}

/// Switcher jump-app policy.
/// - Browsers never appear as jump apps (use pinned tabs).
/// - “Single window” heuristic (≤1 layer-0 CG window) covers most tools.
/// - Always-include list covers utility apps that register multiple CG windows
///   (Stocks, Music, Calendar, …) but still behave as one destination.
enum JumpAppPolicy {
    static let browserIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.apple.Safari", "company.thebrowser.Browser",
    ]

    /// Always list as jump targets when running, even with multiple CG windows.
    static let alwaysJumpIDs: Set<String> = [
        "com.apple.stocks",
        "com.apple.MobileSMS",
        "com.apple.mail",
        "com.apple.iCal",
        "com.apple.Notes",
        "com.apple.reminders",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.weather",
        "com.apple.Maps",
        "com.apple.Photos",
        "com.apple.FaceTime",
        "com.apple.AddressBook",
        "com.apple.systempreferences",
        "com.apple.AccessibilitySettings",
        "com.apple.calculator",
        "com.apple.clock",
        "com.apple.AppStore",
        "com.apple.TV",
        "com.apple.Home",
        "com.apple.freeform",
        "com.apple.iBooksX",
        "com.apple.Dictionary",
        "com.apple.Preview",
        "com.apple.ActivityMonitor",
        "com.apple.TextEdit",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.spotify.client",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserIDs.contains(bundleID)
    }

    static func alwaysJump(_ bundleID: String) -> Bool {
        alwaysJumpIDs.contains(bundleID)
    }

    /// Whether a running app should appear in the Switcher jump list.
    static func isJumpCandidate(bundleID: String, windowCount: Int) -> Bool {
        if isBrowser(bundleID) { return false }
        if alwaysJump(bundleID) { return true }
        return windowCount <= 1
    }
}
