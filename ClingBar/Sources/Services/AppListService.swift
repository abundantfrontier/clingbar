import AppKit
import Combine

struct BarAppItem: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var displayName: String
    var isPinned: Bool
    var isRunning: Bool
    var hasWindowOnCurrentSpace: Bool
    var windowCountOnCurrentSpace: Int
}

/// Focus-zone list only: pins + optional on-Space apps. Never includes Places.
@MainActor
final class AppListService: ObservableObject {
    static let shared = AppListService()

    @Published private(set) var items: [BarAppItem] = []

    private let settings = SettingsStore.shared
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshSource: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        settings.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        settings.$includeUnpinnedOnSpace
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // pinnedTabs don't appear on focus bar

        let nc = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            workspaceObservers.append(token)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        refreshSource = timer
        refresh()
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        refreshSource?.cancel()
        refreshSource = nil
        cancellables.removeAll()
    }

    func refresh() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let onscreen = WindowEnumerator.onscreenWindows(excludingPID: selfPID)

        var windowCount: [String: Int] = [:]
        for win in onscreen {
            guard let bid = win.bundleIdentifier else { continue }
            windowCount[bid, default: 0] += 1
        }

        let runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var result: [BarAppItem] = []
        var seen = Set<String>()

        for pin in settings.pinnedApps {
            let count = windowCount[pin.bundleIdentifier] ?? 0
            let running = runningIDs.contains(pin.bundleIdentifier)
            // Still “owned” by the pin list for unpinned-on-space dedupe, even if hidden.
            seen.insert(pin.bundleIdentifier)

            // Single-destination apps (Stocks, etc.): hide the slot when the only
            // instance lives on another Space. Pin stays in settings and reappears
            // when you return to that Space (or quit the app). Multi-window apps
            // stay visible so we can open a new window here.
            guard FocusBarVisibility.shouldShowPin(
                bundleIdentifier: pin.bundleIdentifier,
                isRunning: running,
                hasWindowOnCurrentSpace: count > 0
            ) else { continue }

            result.append(BarAppItem(
                bundleIdentifier: pin.bundleIdentifier,
                displayName: pin.displayName,
                isPinned: true,
                isRunning: running,
                hasWindowOnCurrentSpace: count > 0,
                windowCountOnCurrentSpace: count
            ))
        }

        if settings.includeUnpinnedOnSpace {
            for win in onscreen {
                guard let bid = win.bundleIdentifier, !seen.contains(bid) else { continue }
                if bid == Bundle.main.bundleIdentifier { continue }
                if bid.hasPrefix("com.apple.controlcenter") { continue }
                if bid.hasPrefix("com.apple.notificationcenter") { continue }
                seen.insert(bid)
                let count = windowCount[bid] ?? 0
                result.append(BarAppItem(
                    bundleIdentifier: bid,
                    displayName: AppIconCache.displayName(forBundleID: bid),
                    isPinned: false,
                    isRunning: true,
                    hasWindowOnCurrentSpace: count > 0,
                    windowCountOnCurrentSpace: count
                ))
            }
        }

        if items != result {
            items = result
        }
    }
}
