import AppKit

/// Short “How ClingBar Works” panel — first-run + status-menu.
@MainActor
final class HelpPanelController: NSObject, NSWindowDelegate {
    static let shared = HelpPanelController()

    private static let didShowKey = "clingbar.didShowHelp.v1"

    private var panel: KeyablePanel?

    private override init() {
        super.init()
    }

    static var hasShownBefore: Bool {
        UserDefaults.standard.bool(forKey: didShowKey)
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: didShowKey)
    }

    /// First launch only — after the bar is up (and after any Accessibility Settings hop).
    func scheduleFirstRunIfNeeded() {
        guard !Self.hasShownBefore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard !Self.hasShownBefore else { return }
            self?.show()
        }
    }

    func show() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        positionCentered()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.markShown()
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Build

    private func buildPanel() {
        let width: CGFloat = 440

        // Normal titled window (not fullSizeContentView) so content sits below the title bar.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.title = "How ClingBar Works"
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.backgroundColor = NSColor.windowBackgroundColor

        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let subtitle = makeWrappingLabel(
            "An edge bar that stays with you.\nIt does not drag you across Spaces.",
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor
        )
        stack.addArrangedSubview(subtitle)

        // Extra air under the lead-in.
        stack.setCustomSpacing(18, after: subtitle)

        let bullets = makeWrappingLabel(
            Self.helpBody,
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        stack.addArrangedSubview(bullets)

        let axNote = makeWrappingLabel(
            "Window raise needs Accessibility permission.\nMenu bar → Request Accessibility…",
            font: .systemFont(ofSize: 11),
            color: .tertiaryLabelColor
        )
        stack.addArrangedSubview(axNote)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(spacer)

        let ok = NSButton(title: "Got It", target: self, action: #selector(gotIt))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        buttonRow.addArrangedSubview(ok)
        stack.addArrangedSubview(buttonRow)

        let inset: CGFloat = 22
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),

            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bullets.widthAnchor.constraint(equalTo: stack.widthAnchor),
            axNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Size the window to the laid-out content so nothing is clipped.
        let fitting = root.fittingSize
        let contentHeight = max(fitting.height, 200)
        panel.setContentSize(NSSize(width: width, height: contentHeight))

        self.panel = panel
    }

    private func makeWrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.preferredMaxLayoutWidth = 440 - 44
        return field
    }

    private static let helpBody = """
    • Focus apps only act on the current Space.
      Raise or open a window here. Never jump to another desktop.

    • Use Apps to add lasting slots to the Focus bar
      (same idea as the defaults).
      Open Here launches once without adding a slot.

    • Anything with a window on this Space shows up on the bar
      like a current task, even if you launched it from the Dock,
      Spotlight, or another Space. No need to pin.
      Right-click → Add to Focus Bar only if you want a lasting slot.
      Unpinned tasks drop off when they leave this Space.

    • Multi-window apps (Terminal, browsers, editors)
      can open a new window on this Space even if they already run elsewhere.

    • Single-window apps (Stocks, System Settings, …)
      only show on the Space where they’re open,
      so you don’t get a dead click.

    • The Spaces control opens system Mission Control (like F3).
      That’s how you change desktops.

    • Drag the handle to move the bar to another edge.
      Right-click a pin for New Window or Remove.
    """

    private func positionCentered() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @objc private func gotIt() {
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}
