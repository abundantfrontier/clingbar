import AppKit

/// Searchable app browser: open an app on this Space, or **add it to the Focus bar**
/// (same lasting slots as the default VS Code / Terminal / … pins).
/// Replaces system Apps.app, which jumps Spaces when selecting a running app.
@MainActor
final class AppsPickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private let settings: SettingsStore
    private let catalog = AppCatalogService.shared

    private var panel: KeyablePanel?
    private var searchField: NSSearchField?
    private var tableView: NSTableView?
    private var modeButton: NSButton?
    private var pinButton: NSButton?
    private var statusLabel: NSTextField?
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    private var results: [CatalogApp] = []
    private var selectedIndex: Int = 0
    private var excludeRunning = false
    private var isLoading = false

    var onDidPick: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
    }

    func toggle(near anchor: NSRect?) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(near: anchor)
        }
    }

    func show(near anchor: NSRect?) {
        NSLog("ClingBar: Apps picker show()")
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        searchField?.stringValue = ""
        selectedIndex = 0
        statusLabel?.stringValue = "Loading…"
        results = catalog.cachedApps()
        tableView?.reloadData()

        position(near: anchor)
        SpaceTransition.rememberFrontmost()
        // orderFrontRegardless works even for accessory apps without activation races.
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeFirstResponder(searchField)

        // Delay outside-click monitor so the opening click doesn't dismiss us.
        installKeyMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.installClickMonitor()
        }
        loadCatalog(query: "")
    }

    func close() {
        removeMonitors()
        panel?.orderOut(nil)
    }

    // MARK: - Build

    private func buildPanel() {
        let width: CGFloat = 360
        let height: CGFloat = 440

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        // NOTE: `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive —
        // combining them aborts on modern macOS (`_validateCollectionBehavior`).
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "Focus Apps"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.minSize = NSSize(width: 280, height: 300)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        panel.contentView = root

        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        root.addSubview(effect)

        let search = NSSearchField(frame: .zero)
        search.placeholderString = "Search apps"
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(search)
        self.searchField = search

        let mode = NSButton(checkboxWithTitle: "Hide running apps", target: self, action: #selector(toggleMode(_:)))
        mode.state = excludeRunning ? .on : .off
        mode.font = .systemFont(ofSize: 11)
        mode.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(mode)
        self.modeButton = mode

        let status = NSTextField(labelWithString: "Loading…")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(status)
        self.statusLabel = status

        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        let table = NSTableView(frame: .zero)
        table.headerView = nil
        table.rowHeight = 40
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.doubleAction = #selector(confirmSelection)
        table.target = self
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.action = #selector(tableSingleClick)
        table.menu = makeTableContextMenu()

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.width = width - 24
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        scroll.documentView = table
        self.tableView = table

        let pin = NSButton(title: "Add to Focus Bar", target: self, action: #selector(pinButtonClicked))
        pin.bezelStyle = .rounded
        pin.controlSize = .small
        pin.font = .systemFont(ofSize: 12, weight: .medium)
        pin.toolTip = "Keep this app on the Focus bar (like the defaults). Click it later to open on this Space. ⌘P"
        pin.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pin)
        self.pinButton = pin

        let open = NSButton(title: "Open Here", target: self, action: #selector(confirmSelection))
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.font = .systemFont(ofSize: 12, weight: .medium)
        open.toolTip = "Open the selected app on this Space without adding it to the bar (↵)"
        open.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(open)

        let hint = NSTextField(labelWithString: "Add to Focus Bar = lasting slot  ·  ↵ open once  ·  ⌘P toggle  ·  esc")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hint)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 36),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            search.heightAnchor.constraint(equalToConstant: 28),

            mode.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            mode.leadingAnchor.constraint(equalTo: search.leadingAnchor),

            status.centerYAnchor.constraint(equalTo: mode.centerYAnchor),
            status.trailingAnchor.constraint(equalTo: search.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: pin.topAnchor, constant: -8),

            pin.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            pin.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            pin.heightAnchor.constraint(equalToConstant: 28),

            open.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            open.centerYAnchor.constraint(equalTo: pin.centerYAnchor),
            open.heightAnchor.constraint(equalToConstant: 28),

            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            hint.heightAnchor.constraint(equalToConstant: 16),
        ])

        self.panel = panel
        updatePinButtonTitle()
        NSLog("ClingBar: Apps picker panel built ok")
    }

    private func makeTableContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pinItem = NSMenuItem(title: "Add to Focus Bar", action: #selector(pinButtonClicked), keyEquivalent: "p")
        pinItem.keyEquivalentModifierMask = .command
        pinItem.target = self
        menu.addItem(pinItem)
        let openItem = NSMenuItem(title: "Open on This Space", action: #selector(confirmSelection), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.delegate = self
        return menu
    }

    private func position(near anchor: NSRect?) {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame

        var origin: NSPoint
        if let anchor, !anchor.isEmpty {
            switch settings.edge {
            case .left:
                origin = NSPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
            case .right:
                origin = NSPoint(x: anchor.minX - size.width - 10, y: anchor.midY - size.height / 2)
            case .top:
                origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 10)
            case .bottom:
                origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
            }
        } else {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        }

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Catalog load (async so UI never freezes)

    private func loadCatalog(query: String) {
        isLoading = true
        statusLabel?.stringValue = "Loading…"

        Task { [weak self] in
            // Avoid capturing MainActor-isolated instance across threads incorrectly.
            let apps = await AppCatalogService.shared.scanAllApps()
            guard let self else { return }
            self.isLoading = false
            self.catalog.apply(apps)
            self.reload(query: self.searchField?.stringValue ?? query)
            NSLog("ClingBar: catalog loaded %d apps", apps.count)
        }
    }

    private func reload(query: String) {
        results = catalog.filtered(
            query: query,
            excludeRunning: excludeRunning,
            from: catalog.allApps
        )
        selectedIndex = results.isEmpty ? 0 : min(selectedIndex, max(0, results.count - 1))
        tableView?.reloadData()
        if !results.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView?.scrollRowToVisible(selectedIndex)
        }
        if !isLoading {
            statusLabel?.stringValue = excludeRunning
                ? "\(results.count) not running"
                : "\(results.count) apps · Space-safe"
        }
        updatePinButtonTitle()
    }

    // MARK: - Monitors

    private func installKeyMonitor() {
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) ?? event
            }
        }
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let screenPoint = NSEvent.mouseLocation
            if !panel.frame.contains(screenPoint) {
                DispatchQueue.main.async { self.close() }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: NSSearchField) {
        selectedIndex = 0
        reload(query: sender.stringValue)
    }

    @objc private func toggleMode(_ sender: NSButton) {
        excludeRunning = sender.state == .on
        selectedIndex = 0
        reload(query: searchField?.stringValue ?? "")
    }

    @objc private func tableSingleClick() {
        // Select row on click; open on double-click / return
        if let row = tableView?.selectedRow, row >= 0 {
            selectedIndex = row
            updatePinButtonTitle()
        }
    }

    @objc private func confirmSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        launch(results[selectedIndex])
    }

    @objc private func pinButtonClicked() {
        togglePinSelected()
    }

    private func launch(_ app: CatalogApp) {
        NSLog("ClingBar: picker launch \(app.bundleIdentifier)")
        let outcome = SpaceAwareActivator.shared.activate(
            bundleIdentifier: app.bundleIdentifier,
            missingWindowPolicy: settings.missingWindowPolicy,
            allowSpaceJump: false
        )
        if case .failed(let message) = outcome {
            NSLog("ClingBar picker: \(message)")
        }
        close()
        onDidPick?()
    }

    private func togglePinSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let app = results[selectedIndex]
        if settings.isPinned(bundleIdentifier: app.bundleIdentifier) {
            settings.unpin(bundleIdentifier: app.bundleIdentifier)
            statusLabel?.stringValue = "Removed \(app.displayName)"
            NSLog("ClingBar: removed focus app \(app.bundleIdentifier)")
        } else {
            settings.pin(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
            statusLabel?.stringValue = "Added \(app.displayName) to Focus bar"
            NSLog("ClingBar: added focus app \(app.bundleIdentifier)")
        }
        updatePinButtonTitle()
        // Refresh row meta without resetting selection.
        let row = selectedIndex
        tableView?.reloadData()
        if results.indices.contains(row) {
            tableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        AppListService.shared.refresh()
        onDidPick?()
    }

    private func updatePinButtonTitle() {
        guard let pinButton else { return }
        guard results.indices.contains(selectedIndex) else {
            pinButton.title = "Add to Focus Bar"
            pinButton.isEnabled = false
            return
        }
        pinButton.isEnabled = true
        let app = results[selectedIndex]
        if settings.isPinned(bundleIdentifier: app.bundleIdentifier) {
            pinButton.title = "Remove from Focus Bar"
            pinButton.toolTip = "Remove this app from the Focus bar (⌘P)"
        } else {
            pinButton.title = "Add to Focus Bar"
            pinButton.toolTip = "Keep this app on the Focus bar (like the defaults). ⌘P"
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible else { return event }

        switch event.keyCode {
        case 53: // escape
            close()
            return nil
        case 36, 76: // return
            // Don't steal ↵ from the pin button if it somehow becomes first responder.
            confirmSelection()
            return nil
        case 125: // down
            moveSelection(1)
            return nil
        case 126: // up
            moveSelection(-1)
            return nil
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command,
               event.charactersIgnoringModifiers?.lowercased() == "p" {
                togglePinSelected()
                return nil
            }
            return event
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
        tableView?.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView?.scrollRowToVisible(selectedIndex)
        updatePinButtonTitle()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AppCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? AppPickerCell) ?? AppPickerCell()
        cell.identifier = id
        guard results.indices.contains(row) else { return cell }
        let app = results[row]
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
        let onSpace = WindowEnumerator.onscreenWindows()
            .contains { $0.bundleIdentifier == app.bundleIdentifier }
        let pinned = settings.isPinned(bundleIdentifier: app.bundleIdentifier)
        cell.configure(app: app, isRunning: running, hasWindowOnSpace: onSpace, isPinned: pinned)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let row = tableView?.selectedRow, row >= 0 {
            selectedIndex = row
            updatePinButtonTitle()
        }
    }

    // Do NOT auto-close on resign key — accessory apps flap key status constantly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return true
    }
}

// MARK: - Context menu

extension AppsPickerController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Point the pin action at the row under the cursor when possible.
        if let table = tableView,
           let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .leftMouseDown {
            let local = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: local)
            if row >= 0 {
                selectedIndex = row
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        updatePinButtonTitle()
        guard results.indices.contains(selectedIndex) else {
            for item in menu.items { item.isEnabled = false }
            return
        }
        let pinned = settings.isPinned(bundleIdentifier: results[selectedIndex].bundleIdentifier)
        for item in menu.items {
            item.isEnabled = true
            if item.action == #selector(pinButtonClicked) {
                item.title = pinned ? "Remove from Focus Bar" : "Add to Focus Bar"
            }
        }
    }
}

// MARK: - Keyable panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Cell

private final class AppPickerCell: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 10)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(app: CatalogApp, isRunning: Bool, hasWindowOnSpace: Bool, isPinned: Bool) {
        iconView.image = AppIconCache.icon(forBundleID: app.bundleIdentifier, size: 26)
        nameLabel.stringValue = app.displayName
        if isPinned {
            if hasWindowOnSpace {
                metaLabel.stringValue = "On Focus bar · this Space"
            } else if isRunning {
                metaLabel.stringValue = "On Focus bar · running"
            } else {
                metaLabel.stringValue = "On Focus bar"
            }
            metaLabel.textColor = .controlAccentColor
        } else if hasWindowOnSpace {
            metaLabel.stringValue = "On this Space"
            metaLabel.textColor = .secondaryLabelColor
        } else if isRunning {
            metaLabel.stringValue = "Running · open here"
            metaLabel.textColor = .secondaryLabelColor
        } else {
            metaLabel.stringValue = "Not running"
            metaLabel.textColor = .tertiaryLabelColor
        }
    }
}
