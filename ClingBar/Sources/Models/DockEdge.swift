import Foundation
import AppKit

enum DockEdge: String, CaseIterable, Codable, Sendable {
    case left
    case right
    case top
    case bottom

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }

    var isVertical: Bool {
        self == .left || self == .right
    }
}
