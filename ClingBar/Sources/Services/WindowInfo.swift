import Foundation
import AppKit
import CoreGraphics

struct WindowInfo: Identifiable, Equatable, Sendable {
    let id: CGWindowID
    let bundleIdentifier: String?
    let ownerPID: pid_t
    let ownerName: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let alpha: Double
    /// True when the window is currently on-screen (typically = current Space for standard windows).
    let isOnscreen: Bool

    var isStandardLayer: Bool { layer == 0 }
}

enum WindowEnumerator {
    /// On-screen windows only — the practical definition of “on the current Space”
    /// for normal app windows without private Space APIs.
    static func onscreenWindows(excludingPID: pid_t? = nil) -> [WindowInfo] {
        list(options: [.optionOnScreenOnly, .excludeDesktopElements], excludingPID: excludingPID)
    }

    /// All windows including off-screen / other Spaces (best-effort).
    static func allWindows(excludingPID: pid_t? = nil) -> [WindowInfo] {
        list(options: [.optionAll, .excludeDesktopElements], excludingPID: excludingPID)
    }

    private static func list(options: CGWindowListOption, excludingPID: pid_t?) -> [WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [WindowInfo] = []
        results.reserveCapacity(info.count)

        for entry in info {
            // Window number may arrive as Int, UInt32, or NSNumber depending on OS.
            let windowID: CGWindowID? = {
                if let n = entry[kCGWindowNumber as String] as? CGWindowID { return n }
                if let n = entry[kCGWindowNumber as String] as? Int { return CGWindowID(n) }
                if let n = entry[kCGWindowNumber as String] as? NSNumber { return CGWindowID(n.uint32Value) }
                return nil
            }()
            guard let windowID,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t
                    ?? (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = entry[kCGWindowLayer as String] as? Int
                    ?? (entry[kCGWindowLayer as String] as? NSNumber)?.intValue else {
                continue
            }

            if let excludingPID, ownerPID == excludingPID { continue }

            // Skip system UI chrome
            if layer != 0 { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            let isOnscreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false

            var bounds = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] {
                let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
                if let rect { bounds = rect }
            }

            // Filter tiny / empty shells
            if bounds.width < 50 || bounds.height < 50 { continue }
            if alpha < 0.05 { continue }

            let bundleID = bundleIdentifier(forPID: ownerPID)

            results.append(WindowInfo(
                id: windowID,
                bundleIdentifier: bundleID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                title: title,
                bounds: bounds,
                layer: layer,
                alpha: alpha,
                isOnscreen: isOnscreen
            ))
        }

        return results
    }

    private static func bundleIdentifier(forPID pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
