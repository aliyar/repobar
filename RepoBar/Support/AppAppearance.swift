import AppKit
import SwiftUI

/// Which appearance RepoBar's own surfaces use. The status item is deliberately left
/// out: it has to follow the menu bar, not the app.
nonisolated enum AppAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil means "whatever the system is set to".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
