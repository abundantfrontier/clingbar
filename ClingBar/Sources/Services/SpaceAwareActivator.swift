import AppKit
import ApplicationServices

/// Activates / cycles app windows with Space-aware policies.
@MainActor
final class SpaceAwareActivator {
    static let shared = SpaceAwareActivator()

    /// Last activated window per bundle ID (for cycling).
    private var lastActivatedWindow: [String: CGWindowID] = [:]
    private var lastClickBundleID: String?
    private var lastClickTime: Date = .distantPast

    private init() {}

    enum Outcome: Equatable {
        case raisedWindow(CGWindowID)
        case jumpedToOtherSpace(CGWindowID)
        case launchedApp
        case openedNewWindow
        case movedWindow(CGWindowID)
        case failed(String)
    }

    /// - Parameter allowSpaceJump: when true (switcher), raise off-Space windows.
    func activate(
        bundleIdentifier: String,
        missingWindowPolicy: MissingWindowPolicy = .openNewWindow,
        allowSpaceJump: Bool = false
    ) -> Outcome {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // CG front-to-back order; filter to real document/app windows on this Space only.
        let onscreen = cycleableWindows(
            WindowEnumerator.onscreenWindows(excludingPID: selfPID)
                .filter { $0.bundleIdentifier == bundleIdentifier }
                .filter { isFocusableAppWindow($0) }
        )

        if !onscreen.isEmpty {
            let target = pickCycleTarget(windows: onscreen, bundleID: bundleIdentifier)
            if raiseWindow(target) {
                lastActivatedWindow[bundleIdentifier] = target.id
                rememberClick(bundleIdentifier)
                return .raisedWindow(target.id)
            }
            // Raise failed (common for Finder): do not fall through to activate-only —
            // that jumps Spaces. Prefer a new window on this Space instead.
            NSLog("ClingBar: raise failed for \(bundleIdentifier) on-Space window; trying new window")
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if running.isEmpty {
            return launchApp(bundleIdentifier: bundleIdentifier)
        }

        if allowSpaceJump {
            return jumpToApp(bundleIdentifier: bundleIdentifier)
        }

        switch missingWindowPolicy {
        case .openNewWindow:
            if openNewWindow(bundleIdentifier: bundleIdentifier, running: running) {
                rememberClick(bundleIdentifier)
                return .openedNewWindow
            }
            return .failed("Could not open a new window for \(bundleIdentifier)")

        case .moveFromOtherSpace:
            if let moved = moveOffspaceWindowToFront(bundleIdentifier: bundleIdentifier) {
                rememberClick(bundleIdentifier)
                return .movedWindow(moved)
            }
            if openNewWindow(bundleIdentifier: bundleIdentifier, running: running) {
                rememberClick(bundleIdentifier)
                return .openedNewWindow
            }
            return .failed("No window available for \(bundleIdentifier)")
        }
    }

    /// Compatibility wrapper.
    func activate(bundleIdentifier: String, policy: MissingWindowPolicy) -> Outcome {
        activate(bundleIdentifier: bundleIdentifier, missingWindowPolicy: policy, allowSpaceJump: false)
    }

    @discardableResult
    func raiseWindowForDestination(_ window: WindowInfo) -> Bool {
        raiseWindow(window)
    }

    /// Former “jump may switch Spaces” entry point.
    /// EXPERIMENTAL Space-switch path is parked (macOS 27 beta WindowServer issues).
    /// Now: stay on current Space only (same as Focus bar).
    func jumpToApp(bundleIdentifier: String) -> Outcome {
        activate(
            bundleIdentifier: bundleIdentifier,
            missingWindowPolicy: .openNewWindow,
            allowSpaceJump: false
        )
    }

    /// Raise a window if it’s on this Space; otherwise do not pull it here.
    /// EXPERIMENTAL off-Space jump via SpaceTransition is parked.
    func jumpToWindow(_ window: WindowInfo) -> Outcome {
        if window.isOnscreen {
            if let bid = window.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                forceActivate(app)
            }
            if raiseWindow(window) {
                if let bid = window.bundleIdentifier {
                    lastActivatedWindow[bid] = window.id
                    rememberClick(bid)
                }
                return .raisedWindow(window.id)
            }
        }
        // Off-Space: open/focus app without AX-raising foreign windows (would move them).
        if let bid = window.bundleIdentifier {
            return activate(
                bundleIdentifier: bid,
                missingWindowPolicy: .openNewWindow,
                allowSpaceJump: false
            )
        }
        return .failed("Window not on this Space")
    }

    private func largestWindow(in windows: [WindowInfo]) -> WindowInfo? {
        windows.max { a, b in
            (a.bounds.width * a.bounds.height) < (b.bounds.width * b.bounds.height)
        }
    }

    /// Ignore tiny / shell CG windows that are not real UI.
    private func largestMeaningfulWindow(in windows: [WindowInfo]) -> WindowInfo? {
        let real = windows.filter { $0.bounds.width >= 200 && $0.bounds.height >= 160 }
        return largestWindow(in: real.isEmpty ? windows : real)
    }

    private func forceActivate(_ app: NSRunningApplication?) {
        guard let app else { return }
        // Prefer plain activate() on modern macOS. activateIgnoringOtherApps is
        // more aggressive and, paired with Space changes, can reassign windows.
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    /// Force a new window on the current Space (context menu "New Window").
    @discardableResult
    func forceNewWindow(bundleIdentifier: String) -> Outcome {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if running.isEmpty {
            return launchApp(bundleIdentifier: bundleIdentifier)
        }
        if openNewWindow(bundleIdentifier: bundleIdentifier, running: running) {
            rememberClick(bundleIdentifier)
            return .openedNewWindow
        }
        return .failed("Could not open a new window for \(bundleIdentifier)")
    }

    // MARK: - Cycling (this Space only)

    /// Drop tiny shells / status floaters so cycle walks real Finder/Chrome windows.
    private func cycleableWindows(_ windows: [WindowInfo]) -> [WindowInfo] {
        let real = windows.filter { $0.bounds.width >= 200 && $0.bounds.height >= 160 }
        return real.isEmpty ? windows : real
    }

    /// Exclude non-folder Finder chrome (and similar) that CG still reports as layer-0.
    private func isFocusableAppWindow(_ window: WindowInfo) -> Bool {
        if window.bundleIdentifier == "com.apple.finder" {
            // Copy/progress sheets, Get Info quirks, empty-title zero-ish shells.
            let t = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "Copy" || t.hasPrefix("Copy ") { return false }
            // Desktop is not a folder window we want to “raise” across Spaces.
            if t == "Desktop" { return false }
        }
        return true
    }

    /// Pick which on-Space window to raise.
    /// - App not frontmost → topmost on-Space window (CG front-to-back index 0).
    /// - App already frontmost → next window in a **stable** order (by window id).
    ///
    /// Important: do **not** cycle using CG front-to-back order. After we raise a
    /// window it becomes index 0, so “next = index 1” only ever alternates two windows.
    private func pickCycleTarget(windows: [WindowInfo], bundleID: String) -> WindowInfo {
        guard windows.count > 1 else { return windows[0] }

        let appIsFront = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.isActive }

        // First bring-to-front: topmost already on this Space.
        if !appIsFront {
            return windows[0]
        }

        // Stable order so raise/z-order reshuffles don’t collapse the cycle to 2.
        let stable = windows.sorted { $0.id < $1.id }
        let anchorID = lastActivatedWindow[bundleID] ?? windows[0].id
        if let idx = stable.firstIndex(where: { $0.id == anchorID }) {
            return stable[(idx + 1) % stable.count]
        }
        return stable[0]
    }

    private func rememberClick(_ bundleID: String) {
        lastClickBundleID = bundleID
        lastClickTime = Date()
    }

    // MARK: - Raise without Space switch

    @discardableResult
    private func raiseWindow(_ window: WindowInfo) -> Bool {
        let isFinder = window.bundleIdentifier == "com.apple.finder"
        let app = NSRunningApplication(processIdentifier: window.ownerPID)

        // Finder: never activate *before* a specific window is raised.
        // `activate` + “switch to Space with open windows” jumps to another desktop’s Finder.
        // Other apps: activate first so AX can target them (Chrome cycle needs this).
        if !isFinder, let app {
            forceActivate(app)
        }

        let appElement = AXUIElementCreateApplication(window.ownerPID)
        if let axWindow = findAXWindow(
            appElement: appElement,
            targetWindowID: window.id,
            title: window.title,
            bounds: window.bounds
        ) {
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if isFinder {
                // Activate only after this Space’s window is main.
                forceActivate(app)
            }
            // Second raise after a tick helps Chrome when activate races with AX.
            DispatchQueue.main.async {
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            return true
        }

        // AX match failed — try AppleScript window index for common apps.
        if raiseViaAppleScript(window) {
            return true
        }

        // Do **not** return true just because the process exists — that used to
        // count a bare activate() as success and jump Spaces for Finder.
        return false
    }

    private func findAXWindow(
        appElement: AXUIElement,
        targetWindowID: CGWindowID,
        title: String,
        bounds: CGRect
    ) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        // 1) Window number (when AX exposes it).
        for axWindow in windows {
            if let id = windowNumber(of: axWindow), id == targetWindowID {
                return axWindow
            }
        }

        // 2) Title (Chrome often has titles; Finder often empty).
        if !title.isEmpty {
            for axWindow in windows {
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let axTitle = titleRef as? String,
                   axTitle == title {
                    return axWindow
                }
            }
        }

        // 3) Frame match (coordinate-system aware). Critical for Finder.
        for axWindow in windows {
            if let frame = axFrame(of: axWindow), framesRoughlyMatch(frame, bounds) {
                return axWindow
            }
        }

        // 4) Do **not** return windows.first — that freezes cycling on the same window.
        return nil
    }

    private func windowNumber(of element: AXUIElement) -> CGWindowID? {
        var ref: CFTypeRef?
        let attrs = ["_AXWindowNumber", "AXWindowNumber"]
        for attr in attrs {
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success {
                if let num = ref as? Int {
                    return CGWindowID(num)
                }
                if let num = ref as? NSNumber {
                    return CGWindowID(num.uint32Value)
                }
            }
        }
        return nil
    }

    /// AX position is bottom-left Cocoa; CGWindow bounds are top-left global.
    private func axFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        let posAX = posVal as! AXValue
        let sizeAX = sizeVal as! AXValue
        guard AXValueGetValue(posAX, .cgPoint, &pos),
              AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }

        // Convert Cocoa bottom-left to CG top-left using main screen height.
        let screenH = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.height ?? 0
        let topLeftY = screenH - pos.y - size.height
        return CGRect(x: pos.x, y: topLeftY, width: size.width, height: size.height)
    }

    private func framesRoughlyMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        let tol: CGFloat = 8
        return abs(a.origin.x - b.origin.x) < tol
            && abs(a.origin.y - b.origin.y) < tol
            && abs(a.width - b.width) < tol
            && abs(a.height - b.height) < tol
    }

    /// Finder / Chrome: set a window’s index when AX identity fails.
    private func raiseViaAppleScript(_ window: WindowInfo) -> Bool {
        guard let bid = window.bundleIdentifier else { return false }
        let appName: String
        switch bid {
        case "com.apple.finder": appName = "Finder"
        case "com.google.Chrome", "com.google.Chrome.canary": appName = "Google Chrome"
        case "com.brave.Browser": appName = "Brave Browser"
        case "com.apple.Safari": appName = "Safari"
        default:
            guard let n = NSRunningApplication(processIdentifier: window.ownerPID)?.localizedName else {
                return false
            }
            appName = n
        }

        // Among AX/script windows of similar size, pick by stable sort of CG list index.
        // AppleScript: bring each window to front until bounds match is heavy; use index
        // from CG front-to-back list among cycleable windows.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let peers = cycleableWindows(
            WindowEnumerator.onscreenWindows(excludingPID: selfPID)
                .filter { $0.bundleIdentifier == bid }
                .filter { isFocusableAppWindow($0) }
        )
        guard let index = peers.firstIndex(where: { $0.id == window.id }) else { return false }
        // AppleScript windows are 1-based; order may not match CG — try set index of window (index+1).
        let scriptIndex = index + 1
        // Finder: set index first, activate last — bare `activate` jumps Spaces.
        if bid == "com.apple.finder" {
            return runOSAscript("""
            tell application "Finder"
                try
                    set index of window \(scriptIndex) to 1
                on error
                    try
                        set index of window 1 to (count of windows)
                        set index of window \(scriptIndex) to 1
                    end try
                end try
                activate
            end tell
            """)
        }
        return runOSAscript("""
        tell application "\(appName)"
            activate
            try
                set index of window \(scriptIndex) to 1
            on error
                try
                    set index of window 1 to (count of windows)
                    set index of window \(scriptIndex) to 1
                end try
            end try
        end tell
        """)
    }

    // MARK: - Launch / new window

    private func launchApp(bundleIdentifier: String) -> Outcome {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return .failed("App not found: \(bundleIdentifier)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("ClingBar launch error: \(error.localizedDescription)")
            }
        }
        return .launchedApp
    }

    /// Open a new window on the *current* Space.
    /// Critical: avoid `activate` on apps that only have windows on other Spaces — that jumps Spaces.
    private func openNewWindow(bundleIdentifier: String, running: [NSRunningApplication]) -> Bool {
        if openNewWindowSpecialCase(bundleIdentifier: bundleIdentifier) {
            return true
        }

        // AX: File / Shell → New Window — do NOT activate first (Space jump).
        if let app = running.first, performNewWindowMenu(pid: app.processIdentifier) {
            return true
        }

        // Generic AppleScript without activate
        if let name = running.first?.localizedName {
            if runOSAscript("""
            tell application "\(name)"
                try
                    make new document
                on error
                    try
                        make new window
                    end try
                end try
            end tell
            """) {
                return true
            }
        }

        return false
    }

    private func openNewWindowSpecialCase(bundleIdentifier: String) -> Bool {
        switch bundleIdentifier {

        // Finder: never `activate` or `NSWorkspace.open(folder)` first — both often
        // focus an existing window on another Space (system “switch to Space with windows”).
        // `make new Finder window` creates on the current Space without jumping.
        case "com.apple.finder":
            if runOSAscript("""
            tell application "Finder"
                make new Finder window to (path to home folder)
            end tell
            """) {
                return true
            }
            // AX: File → New Finder Window (no prior activate).
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
               performNewWindowMenu(pid: app.processIdentifier) {
                return true
            }
            // Last resort: open home without activating (still may reuse; better than jump).
            let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(home, configuration: config)
            return true

        // Terminal: avoid activate (Space jump). Prefer AX menu, then AppleScript.
        case "com.apple.Terminal":
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
               performNewWindowMenu(pid: app.processIdentifier) {
                return true
            }
            // External osascript surfaces Automation TCC more reliably than NSAppleScript.
            if runOSAscript("""
            tell application "Terminal"
                do script ""
            end tell
            """) {
                return true
            }
            // Last fallback: open a directory (may still work when Automation is denied)
            return runProcess(
                "/usr/bin/open",
                arguments: ["-a", "Terminal", NSHomeDirectory()]
            )

        case "com.googlecode.iterm2":
            return runOSAscript("""
            tell application "iTerm"
                create window with default profile
            end tell
            """)

        case "dev.warp.Warp-Stable", "dev.warp.Warp":
            // Prefer AX File → New Window if Warp is running
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
               performNewWindowMenu(pid: app.processIdentifier) {
                return true
            }
            return false

        // Chromium family: --new-window is reliable and stays on current Space.
        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "company.thebrowser.Browser", // Arc
             "com.operasoftware.Opera",
             "com.vivaldi.Vivaldi":
            return openChromiumNewWindow(bundleIdentifier: bundleIdentifier)

        case "com.apple.Safari":
            return runOSAscript("""
            tell application "Safari"
                make new document
            end tell
            """)

        case "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders",
             "com.todesktop.230313mzl4w4u92": // Cursor
            // `open -n` new instance is heavy; prefer AX "New Window", then open folder.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
               performNewWindowMenu(pid: app.processIdentifier) {
                return true
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return runProcess("/usr/bin/open", arguments: ["-na", url.path, "--args", "--new-window"])
            }
            return false

        default:
            return false
        }
    }

    private func openChromiumNewWindow(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        // -n / -a with --args --new-window creates a fresh window on the current Space.
        // `-na` = new instance attempt; Chrome coalesces into one process but honors --new-window.
        return runProcess(
            "/usr/bin/open",
            arguments: ["-na", url.path, "--args", "--new-window"]
        )
    }

    private func performNewWindowMenu(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else {
            return false
        }

        let menuBarElement = menuBar as! AXUIElement
        var menusRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBarElement, kAXChildrenAttribute as CFString, &menusRef) == .success,
              let menus = menusRef as? [AXUIElement] else {
            return false
        }

        // Terminal: Shell → New Window; Finder: File → New Finder Window; others: New Window.
        let menuTitles = ["Shell", "File", "Window"]
        let candidates = [
            "New Finder Window",
            "New Window",
            "New Window with Profile",
            "New Window with Settings…",
            "New Window with Settings",
            "New OS Window",
            "New Incognito Window",
            "New Private Window",
            "New Document",
            "New",
        ]

        for menu in menus {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menu, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let menuTitle = titleRef as? String else {
                continue
            }
            let trimmed = menuTitle.trimmingCharacters(in: .whitespaces)
            guard menuTitles.contains(trimmed) else { continue }

            var itemsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) != .success
                || (itemsRef as? [AXUIElement])?.isEmpty == true {
                // Expand menu so children are populated (does not require app frontmost for all apps).
                AXUIElementPerformAction(menu, kAXPressAction as CFString)
                Thread.sleep(forTimeInterval: 0.08)
                _ = AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef)
            }
            guard let items = itemsRef as? [AXUIElement] else { continue }

            if let item = findMenuItem(in: items, titles: candidates) {
                // Skip disabled items
                var enabledRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(item, kAXEnabledAttribute as CFString, &enabledRef) == .success,
                   let enabled = enabledRef as? Bool, enabled == false {
                    continue
                }
                let press = AXUIElementPerformAction(item, kAXPressAction as CFString)
                if press == .success { return true }
            }
        }

        return false
    }

    private func findMenuItem(in items: [AXUIElement], titles: [String]) -> AXUIElement? {
        for item in items {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String {
                let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                for candidate in titles {
                    if clean == candidate || clean.hasPrefix(candidate) {
                        return item
                    }
                }
            }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement],
               let found = findMenuItem(in: children, titles: titles) {
                return found
            }
        }
        return nil
    }

    private func moveOffspaceWindowToFront(bundleIdentifier: String) -> CGWindowID? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let all = WindowEnumerator.allWindows(excludingPID: selfPID)
            .filter { $0.bundleIdentifier == bundleIdentifier }
        let onscreenIDs = Set(
            WindowEnumerator.onscreenWindows(excludingPID: selfPID).map(\.id)
        )
        let candidates = all.filter { !onscreenIDs.contains($0.id) }
        guard let target = candidates.first ?? all.first else { return nil }

        if raiseWindow(target) {
            lastActivatedWindow[bundleIdentifier] = target.id
            return target.id
        }
        return nil
    }

    // MARK: - Helpers

    /// External `osascript` — surfaces Automation TCC prompts more reliably than NSAppleScript.
    @discardableResult
    private func runOSAscript(_ source: String) -> Bool {
        runProcess("/usr/bin/osascript", arguments: ["-e", source])
    }

    @discardableResult
    private func runProcess(_ launchPath: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                NSLog("ClingBar process failed: \(launchPath) \(arguments) status=\(process.terminationStatus)")
            }
            return process.terminationStatus == 0
        } catch {
            NSLog("ClingBar process error: \(error.localizedDescription)")
            return false
        }
    }
}
