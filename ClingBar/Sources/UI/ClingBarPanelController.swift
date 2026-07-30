import AppKit
import Combine

@MainActor
final class ClingBarPanelController: NSObject {
    private let settings: SettingsStore
    private let appList: AppListService
    private var panel: ClingBarPanel?
    private var contentView: ClingBarContentView?
    private var cancellables = Set<AnyCancellable>()
    private var appsPicker: AppsPickerController?
    // EXPERIMENTAL (parked — macOS 27 beta Space/jump instability):
    // private var appSwitcher: SwitcherController?
    // private var desktopSwitcher: SwitcherController?

    private var mouseMonitor: Any?
    private var isCollapsed = false
    private var screenObserver: NSObjectProtocol?
    private var spaceHandlerToken: UUID?
    private let hotZone: CGFloat = 4
    private let animationDuration: TimeInterval = 0.12
    private var isDraggingBar = false
    private var dragStartMouse = NSPoint.zero
    private var dragStartFrame = NSRect.zero

    init(settings: SettingsStore, appList: AppListService) {
        self.settings = settings
        self.appList = appList
        super.init()
        // Any Space change dismisses selectors — they must not ride along to the next desktop.
        spaceHandlerToken = SpaceService.shared.addSpaceChangedHandler { [weak self] in
            self?.closeAllPopouts()
        }
    }

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        isCollapsed = false
        relayout()
    }

    func hide() { panel?.orderOut(nil) }

    func relayout() {
        guard let panel, let screen = NSScreen.main else { return }
        panel.setFrame(frame(for: settings.edge, screen: screen, collapsed: isCollapsed && settings.autoHide), display: true)
        contentView?.orientation = settings.edge.isVertical ? .vertical : .horizontal
        contentView?.showLabels = settings.showLabels
        contentView?.needsLayout = true
        contentView?.layoutSubtreeIfNeeded()
        contentView?.update(items: appList.items)
    }

    private func buildPanel() {
        let panel = ClingBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.floating` keeps the bar above normal app windows.
        // Do **not** use `.fullScreenAuxiliary` — that draws over Keynote/PowerPoint/
        // browser presentations and other full-screen apps. Without it, macOS keeps
        // the bar on the desktop Spaces only (still sticky via canJoinAllSpaces).
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let content = ClingBarContentView(frame: .zero)
        content.orientation = settings.edge.isVertical ? .vertical : .horizontal
        content.showLabels = settings.showLabels
        content.onActivate = { [weak self] in self?.handleActivate($0) }
        content.onContextMenu = { [weak self] item, pt in self?.showContextMenu(for: item, at: pt) }
        content.onOpenApps = { [weak self] in self?.openApps() }
        content.onOpenDesktopSwitcher = { [weak self] in self?.openMissionControl() }
        content.onDragHandleBegan = { [weak self] in self?.beginBarDrag() }
        content.onDragHandleMoved = { [weak self] in self?.moveBarDrag(to: $0) }
        content.onDragHandleEnded = { [weak self] in self?.endBarDrag(at: $0) }
        panel.contentView = content
        self.panel = panel
        self.contentView = content

        appList.$items.receive(on: RunLoop.main).sink { [weak self] items in
            self?.contentView?.update(items: items)
            self?.relayoutSizeOnly()
        }.store(in: &cancellables)

        settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.relayout()
            self?.updateMouseMonitor()
        }.store(in: &cancellables)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }
        updateMouseMonitor()
        content.update(items: appList.items)
    }

    private func relayoutSizeOnly() {
        guard let panel, let screen = NSScreen.main else { return }
        let f = frame(for: settings.edge, screen: screen, collapsed: isCollapsed && settings.autoHide)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    private func frame(for edge: DockEdge, screen: NSScreen, collapsed: Bool) -> NSRect {
        let visible = screen.visibleFrame
        let thickness = CGFloat(settings.barThickness)
        let count = max(appList.items.count, 1) + ClingBarContentView.chromeSlotCount
        let iconSlot: CGFloat = settings.showLabels ? 52 : 44
        let length = CGFloat(count) * iconSlot + 20
        switch edge {
        case .left:
            let w = collapsed ? hotZone : thickness
            let h = min(length, visible.height - 20)
            return NSRect(x: visible.minX, y: visible.midY - h / 2, width: w, height: h)
        case .right:
            let w = collapsed ? hotZone : thickness
            let h = min(length, visible.height - 20)
            return NSRect(x: visible.maxX - w, y: visible.midY - h / 2, width: w, height: h)
        case .top:
            let h = collapsed ? hotZone : thickness
            let w = min(length, visible.width - 20)
            return NSRect(x: visible.midX - w / 2, y: visible.maxY - h, width: w, height: h)
        case .bottom:
            let h = collapsed ? hotZone : thickness
            let w = min(length, visible.width - 20)
            return NSRect(x: visible.midX - w / 2, y: visible.minY, width: w, height: h)
        }
    }

    // MARK: - Drag

    private func beginBarDrag() {
        guard let panel else { return }
        isDraggingBar = true
        isCollapsed = false
        dragStartMouse = NSEvent.mouseLocation
        dragStartFrame = panel.frame
    }

    private func moveBarDrag(to screenPoint: NSPoint) {
        guard isDraggingBar, let panel else { return }
        var f = dragStartFrame
        f.origin.x += screenPoint.x - dragStartMouse.x
        f.origin.y += screenPoint.y - dragStartMouse.y
        panel.setFrame(f, display: true)
    }

    private func endBarDrag(at screenPoint: NSPoint) {
        guard isDraggingBar else { return }
        isDraggingBar = false
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        guard let screen else { relayout(); return }
        let v = screen.visibleFrame
        let pairs: [(DockEdge, CGFloat)] = [
            (.left, abs(screenPoint.x - v.minX)),
            (.right, abs(screenPoint.x - v.maxX)),
            (.bottom, abs(screenPoint.y - v.minY)),
            (.top, abs(screenPoint.y - v.maxY)),
        ]
        settings.setEdge(pairs.min(by: { $0.1 < $1.1 })?.0 ?? .left)
        relayout()
    }

    // MARK: - Openers

    func openAppsPicker() { openApps() }
    func openDesktopSwitcherPublic() { openMissionControl() }

    private func closeAllPopouts() {
        appsPicker?.close()
    }

    func dismissPopouts() { closeAllPopouts() }

    private func openApps() {
        closeAllPopouts()
        if appsPicker == nil {
            let p = AppsPickerController(settings: settings)
            p.onDidPick = { [weak self] in self?.appList.refresh() }
            appsPicker = p
        }
        let anchor = panel?.frame
        DispatchQueue.main.async { [weak self] in self?.appsPicker?.show(near: anchor) }
    }

    /// Opens system Mission Control (same idea as F3) — stable public path.
    /// Custom in-app Space switch / desk naming is parked until WindowServer is calmer.
    private func openMissionControl() {
        closeAllPopouts()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") {
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            return
        }
        let path = "/System/Applications/Mission Control.app"
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
            return
        }
        // Last resort: `open -a`
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Mission Control"]
        try? p.run()
    }

    // MARK: - Auto-hide

    private func updateMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        guard settings.autoHide else { isCollapsed = false; return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMove() }
        }
    }

    private func handleMouseMove() {
        guard settings.autoHide, panel != nil, let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation
        let expanded = frame(for: settings.edge, screen: screen, collapsed: false)
        let probe = expanded.insetBy(dx: -6, dy: -6)
        let near: Bool
        switch settings.edge {
        case .left: near = mouse.x <= screen.visibleFrame.minX + hotZone + 8 || probe.contains(mouse)
        case .right: near = mouse.x >= screen.visibleFrame.maxX - hotZone - 8 || probe.contains(mouse)
        case .top: near = mouse.y >= screen.visibleFrame.maxY - hotZone - 8 || probe.contains(mouse)
        case .bottom: near = mouse.y <= screen.visibleFrame.minY + hotZone + 8 || probe.contains(mouse)
        }
        if near && isCollapsed {
            isCollapsed = false
            animate(frame(for: settings.edge, screen: screen, collapsed: false))
        } else if !near && !isCollapsed && !probe.contains(mouse) {
            isCollapsed = true
            animate(frame(for: settings.edge, screen: screen, collapsed: true))
        }
    }

    private func animate(_ rect: NSRect) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animationDuration
            panel.animator().setFrame(rect, display: true)
        }
    }

    // MARK: - Focus actions

    private func handleActivate(_ item: BarAppItem) {
        _ = SpaceAwareActivator.shared.activate(
            bundleIdentifier: item.bundleIdentifier,
            missingWindowPolicy: settings.missingWindowPolicy,
            allowSpaceJump: false
        )
        appList.refresh()
    }

    private func showContextMenu(for item: BarAppItem, at location: NSPoint) {
        guard let panel else { return }
        let menu = NSMenu()

        let nw = NSMenuItem(title: "New Window Here", action: #selector(ctxNewWindow(_:)), keyEquivalent: "")
        nw.representedObject = item.bundleIdentifier
        nw.target = self
        menu.addItem(nw)

        menu.addItem(.separator())
        if item.isPinned {
            let rm = NSMenuItem(title: "Remove from Focus Bar", action: #selector(ctxUnpin(_:)), keyEquivalent: "")
            rm.representedObject = item.bundleIdentifier
            rm.target = self
            menu.addItem(rm)
        } else {
            // Temporary on-Space app (not one of the lasting focus slots).
            let pin = NSMenuItem(title: "Add to Focus Bar", action: #selector(ctxPin(_:)), keyEquivalent: "")
            pin.representedObject = item
            pin.target = self
            menu.addItem(pin)
        }

        menu.addItem(.separator())
        for edge in DockEdge.allCases {
            let e = NSMenuItem(title: "Dock \(edge.displayName)", action: #selector(ctxEdge(_:)), keyEquivalent: "")
            e.representedObject = edge.rawValue
            e.state = settings.edge == edge ? .on : .off
            e.target = self
            menu.addItem(e)
        }
        menu.popUp(positioning: nil, at: location, in: panel.contentView)
    }

    @objc private func ctxNewWindow(_ s: NSMenuItem) {
        guard let bid = s.representedObject as? String else { return }
        _ = SpaceAwareActivator.shared.forceNewWindow(bundleIdentifier: bid)
        appList.refresh()
    }
    @objc private func ctxUnpin(_ s: NSMenuItem) {
        guard let bid = s.representedObject as? String else { return }
        settings.unpin(bundleIdentifier: bid)
        appList.refresh()
    }
    @objc private func ctxPin(_ s: NSMenuItem) {
        guard let item = s.representedObject as? BarAppItem else { return }
        settings.pin(bundleIdentifier: item.bundleIdentifier, displayName: item.displayName)
        appList.refresh()
    }
    @objc private func ctxEdge(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let e = DockEdge(rawValue: raw) else { return }
        settings.setEdge(e)
        relayout()
    }
}

final class ClingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
