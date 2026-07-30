import AppKit

enum BarOrientation {
    case vertical
    case horizontal
}

/// Layout: Apps · focus apps · (rule) · Mission Control · drag.
/// Focus = stay on this Space. Spaces button = system Mission Control (F3).
/// App Switcher UI is parked (experimental cross-Space jump).
final class ClingBarContentView: NSView {
    var orientation: BarOrientation = .vertical { didSet { needsLayout = true } }
    var showLabels: Bool = false { didSet { rebuildFocusButtons() } }
    var onActivate: ((BarAppItem) -> Void)?
    var onContextMenu: ((BarAppItem, NSPoint) -> Void)?
    var onOpenApps: (() -> Void)?
    var onOpenDesktopSwitcher: (() -> Void)?
    var onDragHandleBegan: (() -> Void)?
    var onDragHandleMoved: ((NSPoint) -> Void)?
    var onDragHandleEnded: ((NSPoint) -> Void)?

    private var items: [BarAppItem] = []
    private var focusButtons: [BarSlotButton] = []
    private let appsButton = BarSlotButton()
    private let desktopSwitcherButton = BarSlotButton()
    private let topRule = NSView()
    private let bottomRule = NSView()
    private let background = NSVisualEffectView()
    private let dragHandle = DragHandleView()

    /// Apps + Mission Control + drag handle.
    static let chromeSlotCount = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        addSubview(background)

        for rule in [topRule, bottomRule] {
            rule.wantsLayer = true
            rule.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor
            addSubview(rule)
        }

        appsButton.configureAppsLauncher(showLabel: showLabels)
        appsButton.onClick = { [weak self] in self?.onOpenApps?() }
        addSubview(appsButton)

        desktopSwitcherButton.configureDesktopSwitcherLauncher(showLabel: showLabels)
        desktopSwitcherButton.onClick = { [weak self] in self?.onOpenDesktopSwitcher?() }
        addSubview(desktopSwitcherButton)

        dragHandle.toolTip = "Drag to another edge"
        dragHandle.onDragBegan = { [weak self] in self?.onDragHandleBegan?() }
        dragHandle.onDragMoved = { [weak self] p in self?.onDragHandleMoved?(p) }
        dragHandle.onDragEnded = { [weak self] p in self?.onDragHandleEnded?(p) }
        addSubview(dragHandle)

        rebuildFocusButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(items: [BarAppItem]) {
        let changed = self.items != items
        self.items = items
        if changed {
            rebuildFocusButtons()
        } else {
            for (b, item) in zip(focusButtons, items) {
                b.configureApp(item: item, showLabel: showLabels)
            }
        }
        appsButton.configureAppsLauncher(showLabel: showLabels)
        desktopSwitcherButton.configureDesktopSwitcherLauncher(showLabel: showLabels)
        needsLayout = true
    }

    private func rebuildFocusButtons() {
        focusButtons.forEach { $0.removeFromSuperview() }
        focusButtons.removeAll()
        for item in items {
            let button = BarSlotButton()
            button.configureApp(item: item, showLabel: showLabels)
            button.onClick = { [weak self, weak button] in
                guard let self, let button, let cur = button.appItem else { return }
                self.onActivate?(cur)
            }
            button.onRightClick = { [weak self, weak button] loc in
                guard let self, let button, let cur = button.appItem else { return }
                self.onContextMenu?(cur, button.convert(loc, to: self))
            }
            addSubview(button, positioned: .above, relativeTo: background)
            focusButtons.append(button)
        }
        addSubview(topRule, positioned: .above, relativeTo: nil)
        addSubview(bottomRule, positioned: .above, relativeTo: nil)
        addSubview(appsButton, positioned: .above, relativeTo: nil)
        addSubview(desktopSwitcherButton, positioned: .above, relativeTo: nil)
        addSubview(dragHandle, positioned: .above, relativeTo: nil)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let padding: CGFloat = 6
        let spacing: CGFloat = 4
        let handleSize: CGFloat = 20
        let chromeSize: CGFloat = 34
        let rule: CGFloat = 2

        switch orientation {
        case .vertical:
            // Top → bottom: Apps | rule | focus… | rule | Mission Control | drag
            appsButton.frame = NSRect(
                x: padding, y: bounds.height - padding - chromeSize,
                width: bounds.width - padding * 2, height: chromeSize
            )
            topRule.frame = NSRect(
                x: padding + 4, y: appsButton.frame.minY - 6,
                width: bounds.width - padding * 2 - 8, height: rule
            )
            dragHandle.frame = NSRect(
                x: padding, y: padding,
                width: bounds.width - padding * 2, height: handleSize
            )
            desktopSwitcherButton.frame = NSRect(
                x: padding, y: dragHandle.frame.maxY + spacing,
                width: bounds.width - padding * 2, height: chromeSize
            )
            bottomRule.frame = NSRect(
                x: padding + 4, y: desktopSwitcherButton.frame.maxY + 5,
                width: bounds.width - padding * 2 - 8, height: rule
            )
            let topY = topRule.frame.minY - spacing
            let bottomY = bottomRule.frame.maxY + spacing
            let available = max(0, topY - bottomY)
            let n = max(focusButtons.count, 1)
            let slotH = max(28, (available - spacing * CGFloat(max(n - 1, 0))) / CGFloat(n))
            let w = bounds.width - padding * 2
            var y = topY - slotH
            for b in focusButtons {
                b.frame = NSRect(x: padding, y: y, width: w, height: min(slotH, available))
                y -= slotH + spacing
            }

        case .horizontal:
            // Left → right: Apps | rule | focus… | rule | Mission Control | drag
            appsButton.frame = NSRect(x: padding, y: padding, width: chromeSize, height: bounds.height - padding * 2)
            topRule.frame = NSRect(x: appsButton.frame.maxX + 4, y: padding + 6, width: rule, height: bounds.height - padding * 2 - 12)
            dragHandle.frame = NSRect(x: bounds.width - padding - handleSize, y: padding, width: handleSize, height: bounds.height - padding * 2)
            desktopSwitcherButton.frame = NSRect(
                x: dragHandle.frame.minX - spacing - chromeSize, y: padding,
                width: chromeSize, height: bounds.height - padding * 2
            )
            bottomRule.frame = NSRect(
                x: desktopSwitcherButton.frame.minX - 5, y: padding + 6,
                width: rule, height: bounds.height - padding * 2 - 12
            )
            let left = topRule.frame.maxX + spacing
            let right = bottomRule.frame.minX - spacing
            let available = max(0, right - left)
            let n = max(focusButtons.count, 1)
            let slotW = max(28, (available - spacing * CGFloat(max(n - 1, 0))) / CGFloat(n))
            let h = bounds.height - padding * 2
            var x = left
            for b in focusButtons {
                b.frame = NSRect(x: x, y: padding, width: min(slotW, available), height: h)
                x += slotW + spacing
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if dragHandle.frame.contains(local) { return dragHandle }
        if desktopSwitcherButton.frame.contains(local) { return desktopSwitcherButton }
        if appsButton.frame.contains(local) { return appsButton }
        for b in focusButtons.reversed() where b.frame.contains(local) { return b }
        return self
    }
}

// MARK: - Slot

final class BarSlotButton: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    private(set) var appItem: BarAppItem?
    private let iconView = NSImageView()
    private let indicator = NSView()
    private let label = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false
        addSubview(iconView)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 2
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.isHidden = true
        addSubview(indicator)
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isHidden = true
        label.refusesFirstResponder = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        (!isHidden && alphaValue > 0.01 && frame.contains(point)) ? self : nil
    }

    func configureAppsLauncher(showLabel: Bool) {
        appItem = nil
        iconView.image = AppIconCache.systemAppsIcon(size: 28)
        iconView.contentTintColor = nil
        label.stringValue = "Apps"
        label.isHidden = !showLabel
        indicator.isHidden = true
        toolTip = "Apps — open here, or add to the Focus bar"
        needsLayout = true
    }

    func configureDesktopSwitcherLauncher(showLabel: Bool) {
        appItem = nil
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.image = NSImage(
            systemSymbolName: "rectangle.split.3x1.fill",
            accessibilityDescription: "Mission Control"
        )?.withSymbolConfiguration(config)
        iconView.contentTintColor = .systemOrange
        label.stringValue = "Spaces"
        label.isHidden = !showLabel
        indicator.isHidden = true
        toolTip = "Mission Control — change Spaces (like F3)"
        needsLayout = true
    }

    func configureApp(item: BarAppItem, showLabel: Bool) {
        appItem = item
        iconView.contentTintColor = nil
        iconView.image = AppIconCache.icon(forBundleID: item.bundleIdentifier, size: 28)
        iconView.alphaValue = item.hasWindowOnCurrentSpace ? 1 : (item.isRunning ? 0.75 : 0.45)
        label.stringValue = item.displayName
        label.isHidden = !showLabel
        indicator.isHidden = !item.hasWindowOnCurrentSpace
        if item.hasWindowOnCurrentSpace {
            toolTip = "\(item.displayName) — on this Space (click to raise / cycle)"
        } else if item.isRunning {
            toolTip = "\(item.displayName) — open a window on this Space"
        } else {
            toolTip = "\(item.displayName) — launch on this Space"
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let show = !label.isHidden
        let side = max(18, show ? min(bounds.width - 8, bounds.height - 18) : min(bounds.width, bounds.height) - 10)
        iconView.frame = NSRect(
            x: (bounds.width - side) / 2,
            y: show ? bounds.height - side - 4 : (bounds.height - side) / 2,
            width: side, height: side
        )
        indicator.frame = NSRect(x: (bounds.width - 4) / 2, y: 3, width: 4, height: 4)
        if show { label.frame = NSRect(x: 2, y: 2, width: bounds.width - 4, height: 12) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let a = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        tracking = a
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(convert(event.locationInWindow, from: nil)); return
        }
        alphaValue = 0.7
        onClick?()
    }
    override func mouseUp(with event: NSEvent) { alphaValue = 1 }
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(convert(event.locationInWindow, from: nil))
    }
}

final class DragHandleView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private let grip = NSImageView()
    private var dragging = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        let c = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        grip.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(c)
        grip.contentTintColor = .tertiaryLabelColor
        addSubview(grip)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        (!isHidden && frame.contains(point)) ? self : nil
    }
    override func layout() {
        super.layout()
        let s: CGFloat = 16
        grip.frame = NSRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let a = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); tracking = a
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        NSCursor.openHand.push()
    }
    override func mouseExited(with event: NSEvent) {
        if !dragging { layer?.backgroundColor = .clear; NSCursor.pop() }
    }
    override func mouseDown(with event: NSEvent) {
        dragging = true
        NSCursor.closedHand.push()
        onDragBegan?()
        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] ev, stop in
            guard let self, let ev else { stop.pointee = true; return }
            if ev.type == .leftMouseDragged { self.onDragMoved?(NSEvent.mouseLocation) }
            else if ev.type == .leftMouseUp {
                self.onDragEnded?(NSEvent.mouseLocation)
                self.dragging = false
                NSCursor.pop(); NSCursor.pop()
                self.layer?.backgroundColor = .clear
                stop.pointee = true
            }
        }
    }
}
