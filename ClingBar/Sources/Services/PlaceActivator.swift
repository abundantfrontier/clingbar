import AppKit
import ApplicationServices

/// Activate a pinned browser tab (may switch Spaces intentionally).
@MainActor
final class PlaceActivator {
    static let shared = PlaceActivator()
    private init() {}

    enum Outcome: Equatable {
        case raisedOnCurrentSpace
        case jumpedToOtherSpace
        case openedURL
        case failed(String)
    }

    func activate(_ place: Place) -> Outcome {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let bid = place.browserBundleIdentifier

        let onscreen = WindowEnumerator.onscreenWindows(excludingPID: selfPID)
            .filter { $0.bundleIdentifier == bid }
        if let match = firstMatch(onscreen, place: place) {
            if SpaceAwareActivator.shared.raiseWindowForDestination(match) {
                return .raisedOnCurrentSpace
            }
        }

        // Off-Space match: switch to that window’s Space (do not AX-raise — that pulls it here).
        let all = WindowEnumerator.allWindows(excludingPID: selfPID)
            .filter { $0.bundleIdentifier == bid }
        if let match = firstMatch(all, place: place) {
            let outcome = SpaceAwareActivator.shared.jumpToWindow(match)
            switch outcome {
            case .raisedWindow: return .raisedOnCurrentSpace
            case .jumpedToOtherSpace: return .jumpedToOtherSpace
            default: break
            }
        }

        // URL-based activation can switch Spaces via the browser; OK for jump path.
        if let url = place.url, activateTabByURL(browser: bid, urlNeedle: url) {
            return .jumpedToOtherSpace
        }

        if let urlString = place.url, let page = URL(string: urlString) {
            if openURL(page, place: place) { return .openedURL }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return .openedURL
        }
        return .failed("Could not open \(place.displayName)")
    }

    private func firstMatch(_ windows: [WindowInfo], place: Place) -> WindowInfo? {
        if place.titleHints.isEmpty { return windows.first }
        return windows.first { win in
            let t = win.title.lowercased()
            return place.titleHints.contains { t.contains($0.lowercased()) }
                || (place.hostHint.map { t.contains($0.lowercased()) } ?? false)
        } ?? windows.first
    }

    private func openURL(_ pageURL: URL, place: Place) -> Bool {
        let bid = place.browserBundleIdentifier
        if place.openAsAppWindow,
           ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
            "com.microsoft.edgemac", "com.vivaldi.Vivaldi"].contains(bid),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return run("/usr/bin/open", ["-na", appURL.path, "--args", "--app=\(pageURL.absoluteString)"])
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([pageURL], withApplicationAt: appURL, configuration: config)
            return true
        }
        return NSWorkspace.shared.open(pageURL)
    }

    private func activateTabByURL(browser: String, urlNeedle: String) -> Bool {
        let host = (URL(string: urlNeedle)?.host ?? urlNeedle)
            .replacingOccurrences(of: "www.", with: "")
        guard !host.isEmpty else { return false }
        let appName: String
        switch browser {
        case "com.apple.Safari":
            return run("/usr/bin/osascript", ["-e", """
            tell application "Safari"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (URL of t as string) contains "\(host)" then
                                set current tab of w to t
                                set index of w to 1
                                return true
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """])
        case "com.brave.Browser": appName = "Brave Browser"
        case "com.microsoft.edgemac": appName = "Microsoft Edge"
        default: appName = "Google Chrome"
        }
        return run("/usr/bin/osascript", ["-e", """
        tell application "\(appName)"
            activate
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    try
                        if (URL of t as string) contains "\(host)" then
                            set active tab index of w to i
                            set index of w to 1
                            return true
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """])
    }

    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }
}
