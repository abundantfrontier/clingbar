import AppKit

/// Ensure only one ClingBar process runs per user session.
///
/// Double-clicking the app (or `open` / `make run`) while one is already up
/// should re-show the existing bar, not spawn a second status item + edge panel.
enum SingleInstance {
    static let reactivateName = Notification.Name("app.clingbar.ClingBar.reactivate")

    /// - Returns: `true` if this process should continue as the primary instance.
    ///   `false` if another ClingBar is already running (a reactivate ping was sent).
    static func claimOrHandOff() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return true }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me && !$0.isTerminated }

        guard !others.isEmpty else { return true }

        // Ask the live instance to show the bar / status item surface.
        DistributedNotificationCenter.default().postNotificationName(
            reactivateName,
            object: bid,
            userInfo: nil,
            deliverImmediately: true
        )
        NSLog("ClingBar: another instance is running (pid \(others.map(\.processIdentifier))); handing off")
        return false
    }

    /// Observe hand-off pings from duplicate launches.
    static func observeReactivate(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: reactivateName,
            object: Bundle.main.bundleIdentifier,
            queue: .main
        ) { _ in
            handler()
        }
    }

    static func stopObserving(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}
