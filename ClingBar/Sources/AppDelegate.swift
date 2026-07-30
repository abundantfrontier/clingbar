import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: ClingBarPanelController?
    private var statusItem: NSStatusItem?
    private let settings = SettingsStore.shared
    private let appList = AppListService.shared
    private var cancellables = Set<AnyCancellable>()
    private var reactivateObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not call AX trust prompt here — LSUIElement + system sheet at launch
        // garbles the menu bar on macOS 27 until another app activates.
        _ = SpaceService.shared

        panelController = ClingBarPanelController(settings: settings, appList: appList)
        panelController?.show()
        setupStatusItem()
        observeSettings()
        appList.start()

        // Second launch of ClingBar.app → show existing bar instead of a second process.
        reactivateObserver = SingleInstance.observeReactivate { [weak self] in
            self?.handleReactivate()
        }

        // After the bar is up, send user to Settings if needed (Settings owns the menu bar).
        AccessibilityPermission.scheduleLaunchPromptIfNeeded()
        // First-run help a beat later so it doesn’t fight the Accessibility Settings hop.
        HelpPanelController.shared.scheduleFirstRunIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appList.stop()
        if let reactivateObserver {
            SingleInstance.stopObserving(reactivateObserver)
            self.reactivateObserver = nil
        }
    }

    private func handleReactivate() {
        panelController?.show()
        NSLog("ClingBar: reactivated existing instance (duplicate launch hand-off)")
    }

    private func setupStatusItem() {
        // Fixed square so a custom glyph doesn’t collapse in a crowded menu bar.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = AppIconCache.menuBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "ClingBar: Focus bar, Apps, Mission Control, Help, About"
            button.imageScaling = .scaleProportionallyDown
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "ClingBar", action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show ClingBar", action: #selector(showBar), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hide ClingBar", action: #selector(hideBar), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Add Apps to Focus Bar…", action: #selector(browseApps), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Mission Control…", action: #selector(openDesktopSwitcher), keyEquivalent: "d"))
        menu.addItem(.separator())

        let edgeMenu = NSMenu()
        for edge in DockEdge.allCases {
            let ei = NSMenuItem(title: edge.displayName, action: #selector(setEdge(_:)), keyEquivalent: "")
            ei.representedObject = edge.rawValue
            ei.state = settings.edge == edge ? .on : .off
            edgeMenu.addItem(ei)
        }
        let edgeParent = NSMenuItem(title: "Dock Edge", action: nil, keyEquivalent: "")
        edgeParent.submenu = edgeMenu
        menu.addItem(edgeParent)

        let ah = NSMenuItem(title: "Auto-Hide", action: #selector(toggleAutoHide), keyEquivalent: "")
        ah.state = settings.autoHide ? .on : .off
        menu.addItem(ah)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "How ClingBar Works…", action: #selector(showHelp), keyEquivalent: "?"))
        menu.addItem(NSMenuItem(title: "About ClingBar…", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Request Accessibility…", action: #selector(requestAccessibility), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClingBar", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        edgeMenu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func observeSettings() {
        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let menu = self?.statusItem?.menu else { return }
            for item in menu.items {
                if item.title == "Auto-Hide" {
                    item.state = self?.settings.autoHide == true ? .on : .off
                }
                if item.title == "Dock Edge", let sub = item.submenu {
                    for ei in sub.items {
                        ei.state = (ei.representedObject as? String) == self?.settings.edge.rawValue ? .on : .off
                    }
                }
            }
        }.store(in: &cancellables)
    }

    @objc private func showBar() { panelController?.show() }
    @objc private func hideBar() { panelController?.hide() }
    @objc private func browseApps() { panelController?.openAppsPicker() }
    @objc private func openDesktopSwitcher() { panelController?.openDesktopSwitcherPublic() }
    @objc private func setEdge(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let e = DockEdge(rawValue: raw) else { return }
        settings.setEdge(e)
        panelController?.relayout()
    }
    @objc private func toggleAutoHide() {
        settings.setAutoHide(!settings.autoHide)
        panelController?.relayout()
    }
    @objc private func showHelp() { HelpPanelController.shared.show() }
    @objc private func showAbout() { AboutPanelController.shared.show() }
    @objc private func requestAccessibility() { AccessibilityPermission.openSystemSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
