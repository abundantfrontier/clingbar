import AppKit
import ApplicationServices

/// Capture frontmost browser tab for pinning into the switcher.
@MainActor
enum PlaceCapture {
    static let browserIDs = JumpAppPolicy.browserIDs

    struct Snapshot {
        var bundleIdentifier: String
        var appName: String
        var windowTitle: String
        var url: String?
    }

    static func frontmostBrowserSnapshot() -> Snapshot? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // Prefer on-screen front window that is a browser
        if let win = WindowEnumerator.onscreenWindows(excludingPID: selfPID)
            .first(where: { bid in
                guard let b = bid.bundleIdentifier else { return false }
                return browserIDs.contains(b)
            }),
           let bid = win.bundleIdentifier {
            let app = NSRunningApplication(processIdentifier: win.ownerPID)
            let title = win.title.isEmpty
                ? (axTitle(pid: win.ownerPID) ?? app?.localizedName ?? bid)
                : win.title
            let url = activeTabURL(bundleIdentifier: bid) ?? axDocumentURL(pid: win.ownerPID)
            return Snapshot(
                bundleIdentifier: bid,
                appName: app?.localizedName ?? bid,
                windowTitle: title,
                url: url
            )
        }

        // Frontmost app if browser
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != selfPID,
           let bid = app.bundleIdentifier,
           browserIDs.contains(bid) {
            return Snapshot(
                bundleIdentifier: bid,
                appName: app.localizedName ?? bid,
                windowTitle: axTitle(pid: app.processIdentifier) ?? app.localizedName ?? bid,
                url: activeTabURL(bundleIdentifier: bid)
            )
        }
        return nil
    }

    static func place(from snap: Snapshot) -> Place {
        let url = snap.url ?? ""
        let host = URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "")
        var name: String
        if let host, host.contains("mail.google") {
            name = "Gmail"
        } else if let host, host.contains("github.com") {
            let path = URL(string: url)?.path.split(separator: "/").map(String.init) ?? []
            name = path.count >= 2 ? "\(path[0])/\(path[1])" : "GitHub"
        } else if !snap.windowTitle.isEmpty {
            name = snap.windowTitle
                .replacingOccurrences(of: " - Google Chrome", with: "")
                .replacingOccurrences(of: " - Safari", with: "")
                .components(separatedBy: " - ").first?
                .trimmingCharacters(in: .whitespaces) ?? snap.windowTitle
        } else {
            name = host ?? snap.appName
        }
        if name.count > 48 { name = String(name.prefix(45)) + "…" }

        var hints: [String] = []
        if !snap.windowTitle.isEmpty { hints.append(snap.windowTitle) }
        if let host { hints.append(host) }

        return Place(
            id: "tab." + stableHash(url + "|" + snap.bundleIdentifier + "|" + name),
            displayName: name,
            browserBundleIdentifier: snap.bundleIdentifier,
            url: url.isEmpty ? nil : url,
            titleHints: Array(Set(hints)),
            openAsAppWindow: snap.bundleIdentifier != "com.apple.Safari" && !url.isEmpty
        )
    }

    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = ((h << 5) &+ h) &+ UInt64(b) }
        return String(h, radix: 16)
    }

    private static func axTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           focused != nil {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success {
                return t as? String
            }
        }
        return nil
    }

    private static func axDocumentURL(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              focused != nil else { return nil }
        var d: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXDocumentAttribute as CFString, &d) == .success,
              let s = d as? String, s.hasPrefix("http") else { return nil }
        return s
    }

    private static func activeTabURL(bundleIdentifier: String) -> String? {
        let script: String
        switch bundleIdentifier {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                return URL of current tab of front window
            end tell
            """
        case "com.brave.Browser":
            script = """
            tell application "Brave Browser"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        case "com.microsoft.edgemac":
            script = """
            tell application "Microsoft Edge"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        case "com.google.Chrome", "com.google.Chrome.canary":
            script = """
            tell application "Google Chrome"
                if (count of windows) is 0 then return ""
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }
        var err: NSDictionary?
        guard let sc = NSAppleScript(source: script) else { return nil }
        let r = sc.executeAndReturnError(&err)
        if err != nil { return nil }
        let s = r.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }
}
