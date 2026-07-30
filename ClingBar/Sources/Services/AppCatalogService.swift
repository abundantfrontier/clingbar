import AppKit

struct CatalogApp: Identifiable, Equatable, Hashable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let displayName: String
    let path: String
}

/// Enumerates installed apps for the custom searchable picker.
@MainActor
final class AppCatalogService {
    static let shared = AppCatalogService()

    private(set) var allApps: [CatalogApp] = []
    private var lastScan: Date = .distantPast

    private init() {}

    func cachedApps() -> [CatalogApp] {
        allApps
    }

    func apply(_ apps: [CatalogApp]) {
        allApps = apps
        lastScan = Date()
    }

    func filtered(
        query: String,
        excludeRunning: Bool,
        from apps: [CatalogApp]? = nil
    ) -> [CatalogApp] {
        let source = apps ?? allApps
        let running: Set<String> = {
            guard excludeRunning else { return [] }
            return Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return source
            .filter { app in
                if excludeRunning && running.contains(app.bundleIdentifier) { return false }
                if q.isEmpty { return true }
                return app.displayName.lowercased().contains(q)
                    || app.bundleIdentifier.lowercased().contains(q)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Heavy scan — call off the main actor.
    nonisolated func scanAllApps() async -> [CatalogApp] {
        await Task.detached(priority: .userInitiated) {
            Self.scanSync()
        }.value
    }

    nonisolated private static func scanSync() -> [CatalogApp] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/Applications/Utilities",
            "\(home)/Applications",
        ]

        var byBundle: [String: CatalogApp] = [:]
        let fm = FileManager.default
        let selfID = Bundle.main.bundleIdentifier

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { continue }

            // Shallow + one-level deep only (Apps, Utilities folders). Avoid full recursive walk.
            let urls = listAppBundles(in: root, fm: fm)
            for url in urls {
                guard let bundle = Bundle(url: url),
                      let bid = bundle.bundleIdentifier,
                      !bid.isEmpty else { continue }
                if bid == selfID { continue }
                if bid == "com.apple.apps.launcher" { continue }

                let name =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                if let existing = byBundle[bid] {
                    let preferNew = url.path.hasPrefix("/Applications")
                        && !existing.path.hasPrefix("/Applications")
                    if !preferNew { continue }
                }
                byBundle[bid] = CatalogApp(
                    bundleIdentifier: bid,
                    displayName: name,
                    path: url.path
                )
            }
        }

        return Array(byBundle.values)
    }

    /// List `.app` at root and one directory level down (e.g. Utilities).
    nonisolated private static func listAppBundles(in root: String, fm: FileManager) -> [URL] {
        var result: [URL] = []
        guard let entries = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        for url in entries {
            if url.pathExtension == "app" {
                result.append(url)
                continue
            }
            // One level into folders like Utilities (not into .app packages)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let nested = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in nested where child.pathExtension == "app" {
                result.append(child)
            }
        }
        return result
    }
}
