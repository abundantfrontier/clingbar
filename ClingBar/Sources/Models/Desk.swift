import Foundation

/// A named project desk = a macOS Space the user labeled while standing on it.
struct Desk: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// Stable-ish Space id from CGS when available; else a fingerprint string.
    var id: String
    var name: String
    var updatedAt: Date

    init(id: String, name: String, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }
}
