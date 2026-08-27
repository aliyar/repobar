import Foundation

/// Pure description of what the status item shows for a given `MenuBarState`.
/// Unit-tested; `StatusItemView` only draws it.
nonisolated struct StatusItemLayout: Equatable, Sendable {
    enum Glyph: Equatable, Sendable { case branch, paused }

    struct Dot: Equatable, Sendable {
        enum Fill: Equatable, Sendable { case filled, faded, ring, error }
        var color: RepoColor
        var fill: Fill
    }

    /// Default for `MenuBarState.maxDots`; the user picks their own in Settings.
    static let defaultMaxDots = 8
    /// Past this the dots stop being readable and macOS truncates the item anyway.
    static let maxDotsRange = 1...30

    var glyph: Glyph = .branch
    var glyphOpacity: Double = 1
    /// Nothing is being checked right now — paused or offline. The whole item dims so
    /// the dots are not read as a live picture.
    var isDimmed = false
    var dots: [Dot] = []
    var overflow = 0
    var text: String?
    var showsAttentionDot = false

    /// Nothing but the glyph — no dots, no count, no attention dot. True whenever the
    /// chosen style has nothing to report right now.
    var showsOnlyGlyph: Bool {
        dots.isEmpty && overflow == 0 && text == nil && !showsAttentionDot
    }

    static func make(from state: MenuBarState) -> StatusItemLayout {
        var layout = StatusItemLayout()
        layout.glyph = state.isPaused ? .paused : .branch
        layout.isDimmed = state.isPaused || state.isOffline
        layout.glyphOpacity = state.isOffline ? 0.5 : 1

        switch state.style {
        case .dots:
            // `repos` arrives in the panel's order — new commits first, then errors,
            // then by name — so taking the first `limit` keeps what matters most and
            // counts the rest. Asking for four dots always draws four, if there are four.
            let limit = max(1, state.maxDots)
            let candidates = state.showIdleDots
                ? state.repos
                : state.repos.filter { $0.hasChanges || $0.hasError }
            layout.dots = candidates.prefix(limit).map { dot(for: $0, idleStyle: state.idleDotStyle) }
            layout.overflow = max(0, candidates.count - limit)
        case .count:
            let count = state.badgeMode == .repositories ? state.unseenRepoCount : state.unseenCommitCount
            if count > 0 {
                layout.text = count > 999 ? "999+" : String(count)
            } else if state.hasError {
                layout.text = "!"
            }
        case .iconOnly:
            layout.showsAttentionDot = state.unseenRepoCount > 0
        }
        return layout
    }

    private static func dot(for repo: RepoDot, idleStyle: IdleDotStyle) -> Dot {
        if repo.hasChanges { return Dot(color: repo.color, fill: .filled) }
        if repo.hasError { return Dot(color: repo.color, fill: .error) }
        return Dot(color: repo.color, fill: idleStyle == .ring ? .ring : .faded)
    }
}
