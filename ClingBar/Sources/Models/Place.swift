import Foundation

/// A **pinned browser tab** (switch destination). Not a focus-bar item.
struct Place: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String
    var displayName: String
    var browserBundleIdentifier: String
    var url: String?
    var titleHints: [String]
    var openAsAppWindow: Bool

    init(
        id: String = UUID().uuidString,
        displayName: String,
        browserBundleIdentifier: String,
        url: String? = nil,
        titleHints: [String] = [],
        openAsAppWindow: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.browserBundleIdentifier = browserBundleIdentifier
        self.url = url
        self.titleHints = titleHints
        self.openAsAppWindow = openAsAppWindow
    }

    /// Migrate older models that used `kind` / `bundleIdentifier`.
    enum CodingKeys: String, CodingKey {
        case id, displayName, browserBundleIdentifier, url, titleHints, openAsAppWindow
        case bundleIdentifier, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        if let b = try c.decodeIfPresent(String.self, forKey: .browserBundleIdentifier) {
            browserBundleIdentifier = b
        } else {
            browserBundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
        }
        url = try c.decodeIfPresent(String.self, forKey: .url)
        titleHints = try c.decodeIfPresent([String].self, forKey: .titleHints) ?? []
        openAsAppWindow = try c.decodeIfPresent(Bool.self, forKey: .openAsAppWindow) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(browserBundleIdentifier, forKey: .browserBundleIdentifier)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encode(titleHints, forKey: .titleHints)
        try c.encode(openAsAppWindow, forKey: .openAsAppWindow)
    }

    var hostHint: String? {
        guard let url, let host = URL(string: url)?.host else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

enum DefaultBrowserPins {
    static let browserPreference = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.apple.Safari",
    ]

    static func preferredBrowserBundleID() -> String? {
        browserPreference.first { AppIconCache.appExists(bundleID: $0) }
    }

    static func gmail(browserBundleID: String) -> Place {
        Place(
            id: "place.gmail",
            displayName: "Gmail",
            browserBundleIdentifier: browserBundleID,
            url: "https://mail.google.com",
            titleHints: ["Gmail", "Inbox", "mail.google.com"],
            openAsAppWindow: browserBundleID != "com.apple.Safari"
        )
    }

    static func seedIfPossible() -> [Place] {
        guard let b = preferredBrowserBundleID() else { return [] }
        return [gmail(browserBundleID: b)]
    }
}
