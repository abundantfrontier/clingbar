import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var edge: DockEdge
    @Published var autoHide: Bool
    @Published var showLabels: Bool
    @Published var barThickness: Double
    @Published var pinnedApps: [PinnedApp]
    @Published var pinnedTabs: [Place]
    @Published var desks: [Desk]
    @Published var missingWindowPolicy: MissingWindowPolicy
    @Published var includeUnpinnedOnSpace: Bool

    private let defaultsKey = "clingbar.settings.v2"
    private let legacyKey = "clingbar.settings.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        // Defaults first so all stored props are set before didSet/save.
        edge = .left
        autoHide = false
        showLabels = false
        barThickness = 48
        pinnedApps = []
        pinnedTabs = []
        desks = []
        missingWindowPolicy = .openNewWindow
        includeUnpinnedOnSpace = true

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let snap = try? decoder.decode(Snapshot.self, from: data) {
            edge = snap.edge
            autoHide = snap.autoHide
            showLabels = snap.showLabels
            barThickness = snap.barThickness
            pinnedApps = snap.pinnedApps
            pinnedTabs = snap.pinnedTabs
            desks = snap.desks
            missingWindowPolicy = snap.missingWindowPolicy
            includeUnpinnedOnSpace = snap.includeUnpinnedOnSpace
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let leg = try? decoder.decode(LegacySnapshot.self, from: data) {
            edge = leg.edge
            autoHide = leg.autoHide
            showLabels = leg.showLabels
            barThickness = leg.barThickness
            pinnedApps = leg.pinnedApps.map {
                PinnedApp(bundleIdentifier: $0.bundleIdentifier, displayName: $0.displayName)
            }
            let oldPlaces = leg.places ?? leg.destinations?.map {
                Place(
                    id: $0.id,
                    displayName: $0.displayName,
                    browserBundleIdentifier: $0.browserBundleIdentifier,
                    url: $0.url,
                    titleHints: $0.titleHints,
                    openAsAppWindow: $0.openAsAppWindow
                )
            } ?? []
            pinnedTabs = oldPlaces.filter { JumpAppPolicy.isBrowser($0.browserBundleIdentifier) }
            if pinnedTabs.isEmpty {
                pinnedTabs = DefaultBrowserPins.seedIfPossible()
            }
            desks = leg.desks ?? []
            missingWindowPolicy = leg.missingWindowPolicy
            includeUnpinnedOnSpace = leg.includeUnpinnedOnSpace
            persist()
        } else {
            var pins = DefaultPinnedApps.all.filter { AppIconCache.appExists(bundleID: $0.bundleIdentifier) }
            if pins.isEmpty {
                pins = [
                    PinnedApp(bundleIdentifier: "com.apple.finder", displayName: "Finder"),
                    PinnedApp(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal"),
                    PinnedApp(bundleIdentifier: "com.apple.Safari", displayName: "Safari"),
                ]
            }
            pinnedApps = pins
            pinnedTabs = DefaultBrowserPins.seedIfPossible()
            persist()
        }

        // Wire didSet-style persistence
        // (property observers can't call before init completes — use explicit saves in mutators)
    }

    func pin(bundleIdentifier: String, displayName: String) {
        guard !pinnedApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        // Assign a new array so @Published / Combine always emit.
        pinnedApps = pinnedApps + [PinnedApp(bundleIdentifier: bundleIdentifier, displayName: displayName)]
        persist()
    }

    func unpin(bundleIdentifier: String) {
        pinnedApps = pinnedApps.filter { $0.bundleIdentifier != bundleIdentifier }
        persist()
    }

    func isPinned(bundleIdentifier: String) -> Bool {
        pinnedApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func pinTab(_ place: Place) {
        if let i = pinnedTabs.firstIndex(where: { $0.id == place.id }) {
            pinnedTabs[i] = place
        } else if let i = pinnedTabs.firstIndex(where: {
            ($0.url != nil && $0.url == place.url)
                || ($0.displayName == place.displayName
                    && $0.browserBundleIdentifier == place.browserBundleIdentifier)
        }) {
            pinnedTabs[i] = place
        } else {
            pinnedTabs.append(place)
        }
        persist()
    }

    func unpinTab(id: String) {
        pinnedTabs.removeAll { $0.id == id }
        persist()
    }

    func nameDesk(spaceID: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            desks.removeAll { $0.id == spaceID }
        } else if let i = desks.firstIndex(where: { $0.id == spaceID }) {
            desks[i].name = trimmed
            desks[i].updatedAt = Date()
        } else {
            desks.append(Desk(id: spaceID, name: trimmed))
        }
        persist()
    }

    func removeDesk(id: String) {
        desks.removeAll { $0.id == id }
        persist()
    }

    /// Call after direct @Published mutation from UI bindings if any.
    func persist() {
        let snap = Snapshot(
            edge: edge,
            autoHide: autoHide,
            showLabels: showLabels,
            barThickness: barThickness,
            pinnedApps: pinnedApps,
            pinnedTabs: pinnedTabs,
            desks: desks,
            missingWindowPolicy: missingWindowPolicy,
            includeUnpinnedOnSpace: includeUnpinnedOnSpace
        )
        if let data = try? encoder.encode(snap) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// Ensure edge/autoHide changes from menus still save
extension SettingsStore {
    func setEdge(_ e: DockEdge) { edge = e; persist() }
    func setAutoHide(_ v: Bool) { autoHide = v; persist() }
}

enum MissingWindowPolicy: String, Codable, CaseIterable, Sendable {
    case openNewWindow
    case moveFromOtherSpace
}

private struct Snapshot: Codable {
    var edge: DockEdge
    var autoHide: Bool
    var showLabels: Bool
    var barThickness: Double
    var pinnedApps: [PinnedApp]
    var pinnedTabs: [Place]
    var desks: [Desk]
    var missingWindowPolicy: MissingWindowPolicy
    var includeUnpinnedOnSpace: Bool
}

private struct LegacySnapshot: Codable {
    var edge: DockEdge
    var autoHide: Bool
    var showLabels: Bool
    var barThickness: Double
    var pinnedApps: [LegacyPin]
    var places: [Place]?
    var destinations: [LegacyDest]?
    var desks: [Desk]?
    var missingWindowPolicy: MissingWindowPolicy
    var includeUnpinnedOnSpace: Bool
}

private struct LegacyPin: Codable {
    var bundleIdentifier: String
    var displayName: String
}

private struct LegacyDest: Codable {
    var id: String
    var displayName: String
    var browserBundleIdentifier: String
    var url: String
    var titleHints: [String]
    var openAsAppWindow: Bool
}
