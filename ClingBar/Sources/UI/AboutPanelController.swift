import AppKit

/// Compact About sheet: version, short pitch, AFI copyright, MIT.
@MainActor
final class AboutPanelController: NSObject, NSWindowDelegate {
    static let shared = AboutPanelController()

    private var panel: KeyablePanel?

    private override init() {
        super.init()
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
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Build

    private func buildPanel() {
        let width: CGFloat = 360

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.title = "About ClingBar"
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.backgroundColor = NSColor.windowBackgroundColor

        let root = NSView(frame: .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = appIconImage(size: 64)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
        ])
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: "ClingBar")
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.alignment = .center
        stack.addArrangedSubview(name)

        let version = NSTextField(labelWithString: Self.versionString)
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        stack.addArrangedSubview(version)

        stack.setCustomSpacing(16, after: version)

        let blurb = makeWrappingLabel(
            "A sticky edge bar that keeps app switching on the current Space.",
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        blurb.alignment = .center
        stack.addArrangedSubview(blurb)

        stack.setCustomSpacing(16, after: blurb)

        let copyright = makeWrappingLabel(
            "© 2026 Abundant Frontier Institute\nLicensed under the MIT License.",
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        )
        copyright.alignment = .center
        stack.addArrangedSubview(copyright)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let help = NSButton(title: "How It Works…", target: self, action: #selector(openHelp))
        help.bezelStyle = .rounded
        help.controlSize = .small

        let ok = NSButton(title: "OK", target: self, action: #selector(okClicked))
        ok.bezelStyle = .rounded
        ok.controlSize = .small
        ok.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(help)
        buttonRow.addArrangedSubview(ok)
        stack.addArrangedSubview(buttonRow)

        let inset: CGFloat = 22
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),

            blurb.widthAnchor.constraint(equalTo: stack.widthAnchor),
            copyright.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        let fitting = root.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(fitting.height, 240)))
        self.panel = panel
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    private func appIconImage(size: CGFloat) -> NSImage {
        if let icon = NSApp.applicationIconImage {
            let img = icon.copy() as? NSImage ?? icon
            img.size = NSSize(width: size, height: size)
            return img
        }
        return AppIconCache.menuBarIcon()
    }

    private func makeWrappingLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.preferredMaxLayoutWidth = 360 - 44
        return field
    }

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

    @objc private func okClicked() {
        close()
    }

    @objc private func openHelp() {
        close()
        HelpPanelController.shared.show()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        close()
        return false
    }
}
