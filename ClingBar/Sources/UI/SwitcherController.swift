import AppKit

// MARK: - EXPERIMENTAL (parked)
// App Switcher + custom Desktop Switcher are not wired in the product UI.
// Cross-Space jump needs private Space APIs that are unstable on macOS 27 beta.
// Desktop button → system Mission Control; Focus bar handles stay-here apps.
// Keep this file so we can revive switchers later without rewriting from scratch.

/// Two focused switchers (separate bar icons, separate popups):
/// - `.apps` — jump apps + pinned browser tabs
/// - `.desktops` — name this desk + jump to every desktop
@MainActor
final class SwitcherController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate {
    enum Mode {
        case apps
        case desktops
    }

    private let settings: SettingsStore
    private let mode: Mode
    private let spaces = SpaceService.shared

    private var panel: KeyablePanel?
    private var tableView: NSTableView?
    private var deskField: NSTextField?
    private var currentDeskLabel: NSTextField?
    private var statusLabel: NSTextField?
    /// Local key monitor (only receives events while ClingBar is active — rare).
    private var localKeyMonitor: Any?
    /// Global key monitor so ↵/esc/arrows work with a nonactivating panel.
    private var globalKeyMonitor: Any?

    private var rows: [Row] = []
    private var selectedIndex = 0
    private var spaceHandlerToken: UUID?

    var onDidChange: (() -> Void)?

    enum Row: Equatable {
        case section(String)
        case desk(id: String, name: String, systemLabel: String?, isCurrent: Bool, isNamed: Bool)
        case jumpApp(bundleId: String, name: String, onThisSpace: Bool)
        case pinnedTab(Place)
        case empty(String)
    }

    init(settings: SettingsStore, mode: Mode) {
        self.settings = settings
        self.mode = mode
        super.init()
        spaceHandlerToken = spaces.addSpaceChangedHandler { [weak self] in
            guard let self else { return }
            // Always dismiss on Space change — selector is for picking a destination,
            // not for riding along to the next desktop.
            if self.isDismissingForSwitch || self.panel?.isVisible == true {
                self.close()
            }
        }
    }

    deinit {
        // SpaceService is main-actor; best-effort cleanup on main.
        if let spaceHandlerToken {
            let spaces = SpaceService.shared
            let token = spaceHandlerToken
            Task { @MainActor in
                spaces.removeSpaceChangedHandler(token)
            }
        }
    }

    /// Set while a Space jump is in flight so space-change handlers don’t re-touch the UI.
    private var isDismissingForSwitch = false

    func show(near anchor: NSRect?) {
        if panel == nil { build() }
        guard let panel else { return }
        isDismissingForSwitch = false
        spaces.refresh()
        refreshHeader()
        reload()
        position(near: anchor)
        // CRITICAL: do **not** call NSApp.activate.
        // ClingBar is LSUIElement — becoming frontmost + private Space switch
        // produces the garbled composite menu bar (Terminal/Finder menus stacked).
        // Nonactivating panel + orderFrontRegardless keeps the previous app’s menu.
        panel.orderFrontRegardless()
        installKeyMonitors()
    }

    /// Fully dismiss the selector. Safe to call repeatedly (e.g. on every Space change).
    func close() {
        isDismissingForSwitch = true
        removeKeyMonitors()
        guard let panel else { return }
        if panel.isKeyWindow {
            panel.resignKey()
        }
        panel.orderOut(nil)
        if panel.isVisible {
            panel.setIsVisible(false)
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Build

    private func build() {
        let w: CGFloat = mode == .desktops ? 400 : 420
        let h: CGFloat = mode == .desktops ? 460 : 480
        // nonactivatingPanel: clicks work without making ClingBar the frontmost app
        // (frontmost LSUIElement + Space switch = garbled menu bar).
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.backgroundColor = .windowBackgroundColor
        panel.minSize = NSSize(width: 320, height: 320)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        panel.contentView = root

        switch mode {
        case .desktops:
            buildDesktopsChrome(root: root, width: w)
        case .apps:
            buildAppsChrome(root: root, width: w)
        }

        self.panel = panel
    }

    private func buildDesktopsChrome(root: NSView, width w: CGFloat) {
        let header = makeLabel("Desktops", size: 15, weight: .semibold)
        root.addSubview(header)

        let sub = makeLabel("Project names are ClingBar-only — macOS still shows Desktop 1, 2…", size: 11)
        sub.textColor = .secondaryLabelColor
        root.addSubview(sub)

        let current = makeLabel("This desk", size: 11, weight: .semibold)
        root.addSubview(current)
        self.currentDeskLabel = current

        let field = NSTextField(string: "")
        field.placeholderString = "Name this project desk… (click to type)"
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        // Typing needs a key window — only activate ClingBar when the user focuses this field.
        field.target = self
        root.addSubview(field)
        self.deskField = field

        let saveDesk = NSButton(title: "Save name", target: self, action: #selector(saveDeskName))
        saveDesk.bezelStyle = .rounded
        saveDesk.font = .systemFont(ofSize: 11)
        saveDesk.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(saveDesk)

        let status = makeLabel("", size: 11)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        self.statusLabel = status

        let (scroll, table) = makeTable(width: w)
        root.addSubview(scroll)
        self.tableView = table

        let hint = makeLabel("↵ go  ·  ⌫ clear name  ·  esc close", size: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            sub.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            current.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 14),
            current.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            current.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            field.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: saveDesk.leadingAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: 28),

            saveDesk.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            saveDesk.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            hint.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func buildAppsChrome(root: NSView, width w: CGFloat) {
        let header = makeLabel("App Switcher", size: 15, weight: .semibold)
        root.addSubview(header)

        let sub = makeLabel("Jump apps & pinned browser tabs — may switch Spaces", size: 11)
        sub.textColor = .secondaryLabelColor
        root.addSubview(sub)

        let pinTab = NSButton(title: "Pin Current Browser Tab", target: self, action: #selector(pinCurrentTab))
        pinTab.bezelStyle = .rounded
        pinTab.font = .systemFont(ofSize: 12, weight: .medium)
        pinTab.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pinTab)

        let status = makeLabel("", size: 11)
        status.textColor = .secondaryLabelColor
        root.addSubview(status)
        self.statusLabel = status

        let (scroll, table) = makeTable(width: w)
        root.addSubview(scroll)
        self.tableView = table

        let hint = makeLabel("↵ jump  ·  ⌫ remove tab  ·  esc close  ·  Focus bar never jumps", size: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            sub.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            sub.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            pinTab.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 12),
            pinTab.leadingAnchor.constraint(equalTo: header.leadingAnchor),

            status.centerYAnchor.constraint(equalTo: pinTab.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: pinTab.trailingAnchor, constant: 8),

            scroll.topAnchor.constraint(equalTo: pinTab.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),

            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            hint.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func makeTable(width w: CGFloat) -> (NSScrollView, NSTableView) {
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let table = NSTableView(frame: .zero)
        table.headerView = nil
        table.rowHeight = 36
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        // Single click activates (and dismisses); double-click same path.
        table.action = #selector(rowActivated)
        table.doubleAction = #selector(rowActivated)
        table.style = .plain
        let col = NSTableColumn(identifier: .init("c"))
        col.width = w - 24
        table.addTableColumn(col)
        scroll.documentView = table
        return (scroll, table)
    }

    private func position(near anchor: NSRect?) {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let anchor, !anchor.isEmpty {
            switch settings.edge {
            case .left: origin = NSPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
            case .right: origin = NSPoint(x: anchor.minX - size.width - 10, y: anchor.midY - size.height / 2)
            case .top: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 10)
            case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
            }
        } else {
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func refreshHeader() {
        guard mode == .desktops else { return }
        spaces.refresh()
        let id = spaces.currentSpaceID
        let name = settings.desks.first(where: { $0.id == id })?.name
        let sys = spaces.systemDesktopLabel(forSpaceID: id)
        if let name, let sys {
            currentDeskLabel?.stringValue = "This desk: \(name)  (\(sys))"
        } else if let name {
            currentDeskLabel?.stringValue = "This desk: \(name)"
        } else if let sys {
            currentDeskLabel?.stringValue = "This desk: unnamed  (\(sys))"
        } else {
            currentDeskLabel?.stringValue = "This desk: unnamed"
        }
        deskField?.stringValue = name ?? ""
    }

    // MARK: - Rows

    private func reload() {
        spaces.refresh()
        switch mode {
        case .desktops:
            reloadDesktops()
        case .apps:
            reloadApps()
        }
        selectedIndex = min(selectedIndex, max(0, rows.count - 1))
        tableView?.reloadData()
        if !rows.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }
        refreshHeader()
    }

    private func reloadDesktops() {
        let current = spaces.currentSpaceID
        let nameBySpace = Dictionary(uniqueKeysWithValues: settings.desks.map { ($0.id, $0.name) })
        var result: [Row] = []
        result.append(.section("All desktops"))

        let desktopIDs = spaces.desktopSpaceIDs
        if desktopIDs.isEmpty {
            let named = settings.desks.sorted { $0.updatedAt > $1.updatedAt }
            if named.isEmpty {
                result.append(.empty("No desktops detected — try Mission Control once"))
            } else {
                for d in named {
                    result.append(.desk(
                        id: d.id,
                        name: d.name,
                        systemLabel: spaces.systemDesktopLabel(forSpaceID: d.id),
                        isCurrent: d.id == current,
                        isNamed: true
                    ))
                }
            }
        } else {
            for id in desktopIDs {
                let sys = spaces.systemDesktopLabel(forSpaceID: id)
                let project = nameBySpace[id]
                let display: String
                let isNamed: Bool
                if let project, !project.isEmpty {
                    display = project
                    isNamed = true
                } else {
                    display = sys ?? "Desktop"
                    isNamed = false
                }
                result.append(.desk(
                    id: id,
                    name: display,
                    systemLabel: isNamed ? sys : nil,
                    isCurrent: id == current,
                    isNamed: isNamed
                ))
            }
        }
        rows = result
        if spaces.canSwitchSpaces {
            statusLabel?.stringValue = "Click a desktop to switch"
        } else {
            statusLabel?.stringValue = "Desk switch limited on this OS"
        }
    }

    private func reloadApps() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let onscreen = WindowEnumerator.onscreenWindows(excludingPID: selfPID)
        let all = WindowEnumerator.allWindows(excludingPID: selfPID)

        var countByApp: [String: Int] = [:]
        for w in all {
            guard let bid = w.bundleIdentifier else { continue }
            countByApp[bid, default: 0] += 1
        }
        let onscreenApps = Set(onscreen.compactMap(\.bundleIdentifier))
        let running = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.bundleIdentifier)
        )

        var result: [Row] = []
        result.append(.section("Jump apps"))
        var jumpIDs = Set<String>()
        for bid in running {
            if bid == Bundle.main.bundleIdentifier { continue }
            let n = countByApp[bid] ?? 0
            if JumpAppPolicy.isJumpCandidate(bundleID: bid, windowCount: n) {
                jumpIDs.insert(bid)
            }
        }
        let sortedJump = jumpIDs.sorted {
            AppIconCache.displayName(forBundleID: $0)
                .localizedCaseInsensitiveCompare(AppIconCache.displayName(forBundleID: $1)) == .orderedAscending
        }
        if sortedJump.isEmpty {
            result.append(.empty("No jump apps running"))
        } else {
            for bid in sortedJump {
                result.append(.jumpApp(
                    bundleId: bid,
                    name: AppIconCache.displayName(forBundleID: bid),
                    onThisSpace: onscreenApps.contains(bid)
                ))
            }
        }

        result.append(.section("Pinned browser tabs"))
        if settings.pinnedTabs.isEmpty {
            result.append(.empty("Focus a browser tab → Pin Current Browser Tab"))
        } else {
            for tab in settings.pinnedTabs {
                result.append(.pinnedTab(tab))
            }
        }
        rows = result
        statusLabel?.stringValue = "\(sortedJump.count) jump · \(settings.pinnedTabs.count) tabs"
    }

    // MARK: - Actions

    @objc private func saveDeskName() {
        spaces.refresh()
        let name = deskField?.stringValue ?? ""
        settings.nameDesk(spaceID: spaces.currentSpaceID, name: name)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        statusLabel?.stringValue = trimmed.isEmpty ? "Desk name cleared" : "Saved “\(trimmed)” for this Space"
        reload()
        onDidChange?()
    }

    @objc private func pinCurrentTab() {
        guard let snap = PlaceCapture.frontmostBrowserSnapshot() else {
            statusLabel?.stringValue = "Focus a Chrome/Safari/Brave tab first"
            return
        }
        let place = PlaceCapture.place(from: snap)
        settings.pinTab(place)
        statusLabel?.stringValue = "Pinned “\(place.displayName)”"
        reload()
        onDidChange?()
    }

    @objc private func rowActivated() {
        if let r = tableView?.clickedRow, r >= 0 {
            selectedIndex = r
        } else if let r = tableView?.selectedRow, r >= 0 {
            selectedIndex = r
        }
        activateSelection()
    }

    @objc private func activateSelection() {
        // Ignore re-entrant clicks while we are already dismissing for a switch.
        guard !isDismissingForSwitch else { return }
        guard rows.indices.contains(selectedIndex) else { return }
        switch rows[selectedIndex] {
        case .section, .empty:
            break
        case .desk:
            // EXPERIMENTAL: custom desk list + CGS Space switch is parked.
            // Desktop button now opens system Mission Control instead.
            statusLabel?.stringValue = "Use Mission Control (Spaces button) to change desktops"
            close()
        case .jumpApp(let bid, let name, _):
            // Stay on this Space only — no private Space switch (macOS 27 beta instability).
            statusLabel?.stringValue = name
            close()
            _ = SpaceAwareActivator.shared.activate(
                bundleIdentifier: bid,
                missingWindowPolicy: .openNewWindow,
                allowSpaceJump: false
            )
            onDidChange?()
        case .pinnedTab(let place):
            // Prefer on-Space tab raise; PlaceActivator may still open URL if missing.
            close()
            _ = PlaceActivator.shared.activate(place)
            onDidChange?()
        }
    }

    private func removeSelection() {
        guard rows.indices.contains(selectedIndex) else { return }
        switch rows[selectedIndex] {
        case .desk(let id, let name, _, _, let isNamed):
            if isNamed {
                settings.removeDesk(id: id)
                statusLabel?.stringValue = "Cleared name “\(name)” — desktop still listed"
                reload()
            } else {
                statusLabel?.stringValue = "Unnamed desks can’t be removed — name them above if you like"
            }
        case .pinnedTab(let p):
            settings.unpinTab(id: p.id)
            statusLabel?.stringValue = "Removed tab “\(p.displayName)”"
            reload()
        default:
            break
        }
        onDidChange?()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sw")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? SwitcherCell) ?? SwitcherCell()
        cell.identifier = id
        guard rows.indices.contains(row) else { return cell }
        cell.configure(rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[safe: row] {
        case .section, .empty, .none: return false
        default: return true
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = rows[safe: row] { return 26 }
        if case .empty = rows[safe: row] { return 28 }
        return 36
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let r = tableView?.selectedRow, r >= 0 { selectedIndex = r }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        // Only time we allow ClingBar to become active: user is naming a desk.
        guard let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(deskField)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        saveDeskName()
        // Drop frontmost status again so a later Space switch stays clean.
        panel?.resignKey()
    }

    private func installKeyMonitors() {
        removeKeyMonitors()
        // Global: works while nonactivating (ClingBar not frontmost). Cannot swallow events.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            Task { @MainActor in
                self?.handleKeyEvent(e, swallow: false)
            }
        }
        // Local: when briefly active for desk naming, can swallow.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.handleKeyEvent(e, swallow: true) ? nil : e
        }
    }

    /// - Returns: true if the event was handled (local monitor should swallow).
    @discardableResult
    private func handleKeyEvent(_ e: NSEvent, swallow: Bool) -> Bool {
        guard panel?.isVisible == true else { return false }
        // Let text field handle typing when focused.
        if panel?.firstResponder is NSTextView || panel?.firstResponder is NSText { return false }
        switch e.keyCode {
        case 53: // esc
            close()
            return swallow
        case 36, 76: // return
            if let r = tableView?.selectedRow, r >= 0 { selectedIndex = r }
            activateSelection()
            return swallow
        case 125: // down
            move(1)
            return swallow
        case 126: // up
            move(-1)
            return swallow
        case 51, 117: // delete
            removeSelection()
            return swallow
        default:
            return false
        }
    }

    private func removeKeyMonitors() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor); self.globalKeyMonitor = nil }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor); self.localKeyMonitor = nil }
    }

    private func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        var i = selectedIndex
        for _ in 0..<rows.count {
            i = max(0, min(rows.count - 1, i + d))
            switch rows[i] {
            case .section, .empty: continue
            default:
                selectedIndex = i
                tableView?.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                tableView?.scrollRowToVisible(i)
                return
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return true
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Cell

private final class SwitcherCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        addSubview(badge)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: SwitcherController.Row) {
        icon.isHidden = false
        badge.isHidden = false
        icon.contentTintColor = nil
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor

        switch row {
        case .section(let s):
            icon.isHidden = true
            badge.isHidden = true
            title.stringValue = s.uppercased()
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
        case .empty(let s):
            icon.isHidden = true
            badge.isHidden = true
            title.stringValue = s
            title.font = .systemFont(ofSize: 12)
            title.textColor = .tertiaryLabelColor
        case .desk(_, let name, let sys, let cur, let isNamed):
            icon.image = NSImage(
                systemSymbolName: isNamed ? "menubar.dock.rectangle" : "rectangle.split.3x1",
                accessibilityDescription: nil
            )
            icon.contentTintColor = cur ? .controlAccentColor : (isNamed ? .secondaryLabelColor : .tertiaryLabelColor)
            if let sys, isNamed {
                title.stringValue = "\(name)  ·  \(sys)"
            } else {
                title.stringValue = name
            }
            title.textColor = isNamed || cur ? .labelColor : .secondaryLabelColor
            badge.stringValue = cur ? "HERE" : "GO"
            badge.textColor = cur ? .controlAccentColor : .systemOrange
        case .jumpApp(let bid, let name, let here):
            icon.image = AppIconCache.icon(forBundleID: bid, size: 22)
            title.stringValue = name
            badge.stringValue = here ? "HERE" : "JUMP"
            badge.textColor = here ? .systemGreen : .systemOrange
        case .pinnedTab(let p):
            icon.image = AppIconCache.icon(forBundleID: p.browserBundleIdentifier, size: 22)
            title.stringValue = p.displayName
            badge.stringValue = "TAB"
            badge.textColor = .systemPurple
        }
    }
}
