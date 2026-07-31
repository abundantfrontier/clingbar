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
    private var deferredRefreshWork: DispatchWorkItem?
    /// After a Space switch, skip timer-driven full refreshes until settle.
    private var suppressTimerRefreshUntil: Date = .distantPast
    /// While true, full refreshes are deferred; only pin-only updates apply.
    private var awaitingSpaceSettle = false

    private init() {}

    func start() {
        settings.$pinnedApps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(includeUnpinnedTasks: true) }
            .store(in: &cancellables)

        settings.$includeUnpinnedOnSpace
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh(includeUnpinnedTasks: true) }
            .store(in: &cancellables)

        let nc = NSWorkspace.shared.notificationCenter
        let immediate: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in immediate {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(includeUnpinnedTasks: true) }
            }
            workspaceObservers.append(token)
        }

        // Space change: strip temporary tasks *immediately* (pins only) so the bar
        // does not keep the previous Space’s extras and then shrink after filtering.
        // Full “current tasks” pass runs after CG window list settles.
        let spaceToken = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSpaceDidChange()
            }
        }
        workspaceObservers.append(spaceToken)

        let activateToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Don’t re-introduce unpinned tasks mid Space-settle.
                guard let self, !self.awaitingSpaceSettle else { return }
                self.scheduleRefresh(after: 0.2, includeUnpinnedTasks: true)
            }
        }
        workspaceObservers.append(activateToken)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date() < self.suppressTimerRefreshUntil { return }
            if self.awaitingSpaceSettle { return }
            self.refresh(includeUnpinnedTasks: true)
        }
        timer.resume()
        refreshSource = timer

        // First paint: pins only (stable length), then tasks once windows are known.
        refresh(includeUnpinnedTasks: false)
        scheduleRefresh(after: 0.35, includeUnpinnedTasks: true)
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { nc.removeObserver($0) }
        workspaceObservers.removeAll()
        deferredRefreshWork?.cancel()
        deferredRefreshWork = nil
        refreshSource?.cancel()
        refreshSource = nil
        cancellables.removeAll()
    }

    private func handleSpaceDidChange() {
        awaitingSpaceSettle = true
        // Drop previous Space’s current tasks right away — bar stays at pin length.
        refresh(includeUnpinnedTasks: false)
        scheduleRefresh(after: 0.5, includeUnpinnedTasks: true)
    }

    private func scheduleRefresh(after delay: TimeInterval, includeUnpinnedTasks: Bool) {
        deferredRefreshWork?.cancel()
        suppressTimerRefreshUntil = Date().addingTimeInterval(delay + 0.15)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.awaitingSpaceSettle = false
            self.refresh(includeUnpinnedTasks: includeUnpinnedTasks)
        }
        deferredRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// - Parameter includeUnpinnedTasks: when false, only lasting Focus pins (stable bar length).
    func refresh(includeUnpinnedTasks: Bool = true) {
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
            seen.insert(pin.bundleIdentifier)

            // Always keep pins (stable length across Space switches).
            result.append(BarAppItem(
                bundleIdentifier: pin.bundleIdentifier,
                displayName: pin.displayName,
                isPinned: true,
                isRunning: running,
                hasWindowOnCurrentSpace: count > 0,
                windowCountOnCurrentSpace: count
            ))
        }

        if includeUnpinnedTasks, settings.includeUnpinnedOnSpace {
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
