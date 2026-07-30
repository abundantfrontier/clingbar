import AppKit

// MARK: - EXPERIMENTAL (parked)
// Custom Space switching via private CGS/SkyLight is disabled in the product UI
// for now (macOS 27 beta menu-bar / window-follow bugs). Desktop button opens
// system Mission Control instead. Keep this module for a future revisit.
//
// Call sites should not invoke switchSpace / parkFrontmost in shipping paths.

/// Space switches that neither steal windows nor garble the menu bar.
///
/// macOS behavior we work around:
/// - If a **regular** app is frontmost during `CGSManagedDisplaySetCurrentSpace`,
///   its windows often **follow** to the destination Space (Terminal “comes with you”).
/// - If **ClingBar** (LSUIElement) is frontmost during the switch, the menu bar
///   becomes a **composite garble** (stacked File/Edit/… from several apps).
///
/// Safe sequence:
/// 1. Switchers stay **nonactivating** (ClingBar never becomes frontmost).
/// 2. **Hide** the current frontmost regular app (windows stay on their Spaces).
/// 3. Private Space switch (nothing rides along).
/// 4. Activate an app already on the **destination** Space (clean menu bar).
/// 5. **Unhide** the parked app (windows reappear on their original Spaces).
/// 6. Toggle menu bar visibility to clear any leftover composite drawing.
@MainActor
enum SpaceTransition {
    private static var hiddenForSwitch: NSRunningApplication?

    /// Hide frontmost regular app so it cannot follow the Space switch.
    static func parkFrontmostApp() {
        // Don't stack parks.
        if hiddenForSwitch != nil { return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier,
              front.activationPolicy == .regular,
              !front.isHidden
        else { return }
        hiddenForSwitch = front
        front.hide()
    }

    static func unparkFrontmostApp() {
        guard let app = hiddenForSwitch else { return }
        hiddenForSwitch = nil
        guard !app.isTerminated else { return }
        app.unhide()
    }

    static func yieldMenuBar(then work: @escaping () -> Void) {
        for window in NSApp.windows where window.isKeyWindow {
            window.resignKey()
        }
        parkFrontmostApp()
        DispatchQueue.main.async {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    /// - Parameter preferringBundleID: after switch, try to make this app the menu-bar owner
    ///   (used for app-jump). Desktop-only switches pass nil.
    static func switchSpace(
        id: String,
        preferringBundleID: String? = nil,
        afterSettled: (() -> Void)? = nil
    ) {
        yieldMenuBar {
            let ok = SpaceService.shared.switchToSpace(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                SpaceService.shared.refresh()

                // Destination menu-bar owner first (never the parked app).
                adoptMenuBarFromCurrentSpace(preferring: preferringBundleID)
                refreshMenuBar()

                // Caller follow-up (e.g. raise jumped window) while parked app still hidden.
                afterSettled?()

                // Restore parked app last — windows stay on original Spaces.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    unparkFrontmostApp()
                    // Re-assert destination owner if unhide briefly stole focus.
                    if let preferringBundleID {
                        adoptMenuBarFromCurrentSpace(preferring: preferringBundleID)
                    } else {
                        adoptMenuBarFromCurrentSpace()
                    }
                    refreshMenuBar()
                }

                if !ok {
                    NSLog("ClingBar: switchToSpace reported failure for id=%@", id)
                }
            }
        }
    }

    /// Activate the largest regular-app window already on-screen (this Space only).
    static func adoptMenuBarFromCurrentSpace(preferring preferredBundleID: String? = nil) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let parkedID = hiddenForSwitch?.bundleIdentifier

        var candidates = WindowEnumerator.onscreenWindows(excludingPID: selfPID)
            .filter { win in
                guard win.bounds.width >= 200, win.bounds.height >= 160 else { return false }
                guard let bid = win.bundleIdentifier, bid != Bundle.main.bundleIdentifier else {
                    return false
                }
                if let parkedID, bid == parkedID { return false }
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                return apps.contains { $0.activationPolicy == .regular && !$0.isHidden }
            }

        if let preferredBundleID {
            let preferred = candidates.filter { $0.bundleIdentifier == preferredBundleID }
            if !preferred.isEmpty { candidates = preferred }
        }

        guard let best = candidates.max(by: {
            ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
        }), let bid = best.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        else {
            return
        }

        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    static func refreshMenuBar() {
        NSMenu.setMenuBarVisible(false)
        NSMenu.setMenuBarVisible(true)
    }

    static func rememberFrontmost() {}
    static func clearSavedFrontmost() {
        unparkFrontmostApp()
    }
}
