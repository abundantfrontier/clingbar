import AppKit

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// Bundle ID for the system searchable Apps launcher (macOS 26+).
    static let systemAppsLauncherBundleID = "com.apple.apps.launcher"

    static func icon(forBundleID bundleID: String, size: CGFloat = 32) -> NSImage {
        lock.lock()
        defer { lock.unlock() }

        let key = "\(bundleID)@\(Int(size))"
        if let cached = cache[key] {
            return cached
        }

        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else if bundleID == systemAppsLauncherBundleID,
                  FileManager.default.fileExists(atPath: "/System/Applications/Apps.app") {
            image = NSWorkspace.shared.icon(forFile: "/System/Applications/Apps.app")
        } else {
            image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: size, height: size))
        }
        // Copy so we don't mutate the shared workspace icon cache entry.
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: size, height: size)
        cache[key] = sized
        return sized
    }

    /// Official system Apps launcher icon (colorful rounded squares + search).
    static func systemAppsIcon(size: CGFloat = 28) -> NSImage {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: systemAppsLauncherBundleID) != nil {
            return icon(forBundleID: systemAppsLauncherBundleID, size: size)
        }
        if FileManager.default.fileExists(atPath: "/System/Applications/Apps.app") {
            lock.lock()
            defer { lock.unlock() }
            let key = "system.apps.path@\(Int(size))"
            if let cached = cache[key] { return cached }
            let image = NSWorkspace.shared.icon(forFile: "/System/Applications/Apps.app")
            let sized = image.copy() as? NSImage ?? image
            sized.size = NSSize(width: size, height: size)
            cache[key] = sized
            return sized
        }
        // Fallback if Apps.app isn't present (older macOS)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .semibold)
        return NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Apps")?
            .withSymbolConfiguration(config)
            ?? NSImage(size: NSSize(width: size, height: size))
    }

    static func appExists(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func displayName(forBundleID bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String else {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return name
    }

    /// Menu-bar template icon: thin edge bar with app slots (reads clearly at 18pt).
    static func menuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ink = NSColor.black
            ink.set()

            // Screen outline (right-biased so the edge bar reads as “left dock”)
            let screen = NSBezierPath(
                roundedRect: NSRect(x: 5.5, y: 2.5, width: 11, height: 13),
                xRadius: 2.2,
                yRadius: 2.2
            )
            screen.lineWidth = 1.4
            screen.stroke()

            // Cling edge bar flush to the left of the screen
            let bar = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 3.5, width: 3.2, height: 11),
                xRadius: 1.2,
                yRadius: 1.2
            )
            bar.fill()

            // Three app “slots” punched out of the bar (template: clear = negative)
            NSGraphicsContext.current?.compositingOperation = .clear
            for i in 0..<3 {
                let y = 5.2 + CGFloat(i) * 2.9
                let slot = NSBezierPath(
                    roundedRect: NSRect(x: 2.1, y: y, width: 2.0, height: 1.8),
                    xRadius: 0.4,
                    yRadius: 0.4
                )
                slot.fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ClingBar"
        return image
    }
}
