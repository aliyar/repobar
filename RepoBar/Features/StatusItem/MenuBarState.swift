import Foundation

nonisolated enum MenuBarStyle: String, CaseIterable, Codable, Sendable {
    case dots, count, iconOnly

    var displayName: String {
        switch self {
        case .dots: "Dots"
        case .count: "Count"
        case .iconOnly: "Icon only"
        }
    }
}

nonisolated enum IdleDotStyle: String, CaseIterable, Codable, Sendable {
    case faded, ring

    var displayName: String {
        switch self {
        case .faded: "Faded"
        case .ring: "Ring"
        }
    }
}

nonisolated enum BadgeMode: String, CaseIterable, Codable, Sendable {
    case repositories, commits

    var displayName: String {
        switch self {
        case .repositories: "Repositories"
        case .commits: "Commits"
        }
    }
}

/// One repository as seen by the menu bar.
nonisolated struct RepoDot: Equatable, Identifiable, Sendable {
    var id: UUID
    var color: RepoColor
    var unseen: Int
    var hasError: Bool

    var hasChanges: Bool { unseen > 0 }
}

/// Everything the status item needs to draw itself. Derived by `AppModel`; pure data.
nonisolated struct MenuBarState: Equatable, Sendable {
    var repos: [RepoDot] = []
    var isChecking = false
    var isPaused = false
    var isOffline = false
    var style: MenuBarStyle = .dots
    var showIdleDots = true
    var idleDotStyle: IdleDotStyle = .ring
    var badgeMode: BadgeMode = .repositories

    var unseenRepoCount: Int { repos.filter(\.hasChanges).count }
    var unseenCommitCount: Int { repos.reduce(0) { $0 + $1.unseen } }
    var hasError: Bool { repos.contains(where: \.hasError) }

    /// Human-readable summary used for the tooltip and accessibility label.
    var summary: String {
        if isPaused { return "RepoBar — paused" }
        if repos.isEmpty { return "RepoBar — no repositories" }
        let changed = unseenRepoCount
        var text = changed == 0
            ? "RepoBar — all \(repos.count) repositories up to date"
            : "RepoBar — \(changed) of \(repos.count) repositories have new commits"
        if hasError { text += " (some checks failed)" }
        if isOffline { text += " — offline" }
        return text
    }

    static let sample: MenuBarState = {
        let colors: [RepoColor] = [.red, .blue, .green, .orange, .purple]
        let dots = colors.enumerated().map { index, color in
            RepoDot(id: UUID(), color: color, unseen: index.isMultiple(of: 2) ? index + 1 : 0, hasError: index == 3)
        }
        return MenuBarState(repos: dots)
    }()
}
