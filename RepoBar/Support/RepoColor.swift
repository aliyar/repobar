import SwiftUI

/// Per-repository color used for the menu-bar dots and the panel rows.
/// Ordered so that neighbours in the palette contrast well; new repos take the least-used color.
nonisolated enum RepoColor: String, CaseIterable, Codable, Sendable, Hashable {
    case red, blue, green, orange, purple, teal, pink, yellow, indigo, mint, brown, cyan

    var color: Color {
        switch self {
        case .red: .red
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .teal: .teal
        case .pink: .pink
        case .yellow: .yellow
        case .indigo: .indigo
        case .mint: .mint
        case .brown: .brown
        case .cyan: .cyan
        }
    }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .purple: .systemPurple
        case .teal: .systemTeal
        case .pink: .systemPink
        case .yellow: .systemYellow
        case .indigo: .systemIndigo
        case .mint: .systemMint
        case .brown: .systemBrown
        case .cyan: .systemCyan
        }
    }

    var displayName: String { rawValue.capitalized }

    /// Picks the least-used color, breaking ties by palette order.
    static func next(excluding used: some Sequence<RepoColor>) -> RepoColor {
        var counts: [RepoColor: Int] = [:]
        for color in used { counts[color, default: 0] += 1 }
        return allCases.enumerated().min { lhs, rhs in
            (counts[lhs.element] ?? 0, lhs.offset) < (counts[rhs.element] ?? 0, rhs.offset)
        }?.element ?? .blue
    }
}
