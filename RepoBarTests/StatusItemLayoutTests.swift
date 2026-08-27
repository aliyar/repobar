import Foundation
import Testing
import GitEngine
@testable import RepoBar

@Suite("StatusItemLayout")
struct StatusItemLayoutTests {
    func dots(_ specs: [(RepoColor, Int, Bool)]) -> [RepoDot] {
        specs.map { RepoDot(id: UUID(), color: $0.0, unseen: $0.1, hasError: $0.2) }
    }

    @Test func dotsStyleShowsAllReposUpToEight() {
        var state = MenuBarState(repos: dots([(.red, 2, false), (.blue, 0, false), (.green, 0, true)]))
        state.style = .dots
        let layout = StatusItemLayout.make(from: state)
        #expect(layout.dots.map(\.fill) == [.filled, .ring, .error])
        #expect(layout.dots.map(\.color) == [.red, .blue, .green])
        #expect(layout.overflow == 0)
        #expect(layout.text == nil)

        state.idleDotStyle = .faded
        #expect(StatusItemLayout.make(from: state).dots[1].fill == .faded)

        state.showIdleDots = false
        let changedOnly = StatusItemLayout.make(from: state)
        #expect(changedOnly.dots.map(\.color) == [.red, .green], "idle repos hidden, errors kept")
    }

    @Test func dotsStyleCollapsesWhenManyRepos() {
        var specs: [(RepoColor, Int, Bool)] = []
        for index in 0..<12 { specs.append((RepoColor.allCases[index % 12], index.isMultiple(of: 2) ? 1 : 0, false)) }
        let state = MenuBarState(repos: dots(specs))
        let layout = StatusItemLayout.make(from: state)
        // The limit is filled from the top of the list and the rest is counted.
        #expect(layout.dots.count == StatusItemLayout.defaultMaxDots)
        #expect(layout.overflow == 12 - StatusItemLayout.defaultMaxDots)

        var hidingIdle = state
        hidingIdle.showIdleDots = false
        let changedOnly = StatusItemLayout.make(from: hidingIdle)
        #expect(changedOnly.dots.count == 6, "six of the twelve have news")
        #expect(changedOnly.dots.allSatisfy { $0.fill == .filled })
        #expect(changedOnly.overflow == 0)
    }

    @Test func countStyle() {
        var state = MenuBarState(repos: dots([(.red, 2, false), (.blue, 3, false), (.green, 0, false)]))
        state.style = .count
        #expect(StatusItemLayout.make(from: state).text == "2")
        state.badgeMode = .commits
        #expect(StatusItemLayout.make(from: state).text == "5")
        state.repos = dots([(.red, 0, true)])
        #expect(StatusItemLayout.make(from: state).text == "!")
        state.repos = []
        #expect(StatusItemLayout.make(from: state).text == nil)
    }

    @Test func iconOnlyPausedAndOffline() {
        var state = MenuBarState(repos: dots([(.red, 1, false)]))
        state.style = .iconOnly
        #expect(StatusItemLayout.make(from: state).showsAttentionDot)
        #expect(StatusItemLayout.make(from: state).dots.isEmpty)
        state.isPaused = true
        #expect(StatusItemLayout.make(from: state).glyph == .paused)
        state.isOffline = true
        #expect(StatusItemLayout.make(from: state).glyphOpacity == 0.5)
    }

    @Test func summaryText() {
        var state = MenuBarState(repos: dots([(.red, 1, false), (.blue, 0, false), (.green, 0, false), (.orange, 0, true), (.purple, 4, false)]))
        #expect(state.summary == "RepoBar — 2 of 5 repositories have new commits (some checks failed)")
        state.repos = dots([(.red, 0, false)])
        #expect(state.summary == "RepoBar — all 1 repositories up to date")
        state.isPaused = true
        #expect(state.summary == "RepoBar — paused")
        #expect(MenuBarState().summary == "RepoBar — no repositories")
    }
}

@Suite("RepoColor")
struct RepoColorTests {
    @Test func picksLeastUsedInPaletteOrder() {
        #expect(RepoColor.next(excluding: []) == .red)
        #expect(RepoColor.next(excluding: [.red]) == .blue)
        #expect(RepoColor.next(excluding: RepoColor.allCases) == .red, "all used once → start over")
        #expect(RepoColor.next(excluding: RepoColor.allCases + [.red]) == .blue)
    }
}

@Suite("RepoSorting")
struct RepoSortingTests {
    func item(_ name: String, unseen: Int = 0, error: RepoError? = nil, order: Int = 0) -> RepoItem {
        let record = RepoRecord(path: "/tmp/\(name)", gitCommonDir: "/tmp/\(name)/.git", sortOrder: order)
        var snapshot = RepoSnapshot(checkedAt: Date(), unseenCount: unseen)
        snapshot.error = error
        snapshot.head = .branch(name: "main", sha: "abc")
        return RepoItem(record: record, snapshot: snapshot, isChecking: false, color: .blue)
    }

    @Test func unseenThenErrorsThenName() {
        let items = [item("zeta"), item("alpha", error: .networkUnreachable), item("mid", unseen: 1), item("top", unseen: 5), item("beta")]
        let sorted = RepoSorting.sort(items).map(\.name)
        #expect(sorted == ["top", "mid", "alpha", "beta", "zeta"])
    }

    @Test func filterMatchesNamePathAndBranch() {
        let items = [item("website"), item("api-server")]
        #expect(RepoSorting.filter(items, query: "web").map(\.name) == ["website"])
        #expect(RepoSorting.filter(items, query: "/tmp/api").map(\.name) == ["api-server"])
        #expect(RepoSorting.filter(items, query: "MAIN").count == 2)
        #expect(RepoSorting.filter(items, query: "  ").count == 2)
    }
}

@Suite("RelativeTimeText")
struct RelativeTimeTextTests {
    @Test func justNowAndAgo() {
        let now = Date()
        #expect(RelativeTimeText.string(for: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(RelativeTimeText.string(for: now.addingTimeInterval(-120), now: now).contains("ago"))
    }
}

@Suite("ExternalAppCatalog")
struct ExternalAppCatalogTests {
    @Test func finderAlwaysPresentAndOthersFiltered() {
        let installed = ExternalAppCatalog.installed { $0 == "com.microsoft.VSCode" }
        #expect(installed.map(\.id) == ["com.apple.finder", "com.microsoft.VSCode"])
        #expect(ExternalAppCatalog.installed { _ in false } == [.finder])
        #expect(ExternalAppCatalog.app(withID: "dev.zed.Zed")?.kind == .editor)
    }
}

@Suite("Status item dimming")
struct StatusItemDimmingTests {
    func state() -> MenuBarState {
        var state = MenuBarState(repos: [RepoDot(id: UUID(), color: .red, unseen: 1, hasError: false)])
        state.style = .dots
        return state
    }

    @Test func liveStateIsFullyDrawn() {
        #expect(!StatusItemLayout.make(from: state()).isDimmed)
    }

    @Test func pausedDimsTheWholeItem() {
        var state = state()
        state.isPaused = true
        let layout = StatusItemLayout.make(from: state)
        #expect(layout.isDimmed, "dots must not read as live while checks are paused")
        #expect(layout.glyph == .paused)
    }

    @Test func offlineDimsTooAndKeepsTheBranchGlyph() {
        var state = state()
        state.isOffline = true
        let layout = StatusItemLayout.make(from: state)
        #expect(layout.isDimmed)
        #expect(layout.glyph == .branch)
    }
}

@Suite("Dot limit")
struct DotLimitTests {
    func state(_ count: Int, unseen: Set<Int> = [], max: Int) -> MenuBarState {
        var state = MenuBarState(repos: (0..<count).map {
            RepoDot(id: UUID(), color: .blue, unseen: unseen.contains($0) ? 1 : 0, hasError: false)
        })
        state.style = .dots
        state.maxDots = max
        return state
    }

    @Test func everythingFitsUnderTheLimit() {
        let layout = StatusItemLayout.make(from: state(6, max: 8))
        #expect(layout.dots.count == 6)
        #expect(layout.overflow == 0)
    }

    @Test func overTheLimitTheBarStaysFull() {
        let layout = StatusItemLayout.make(from: state(11, unseen: [2, 5], max: 8))
        #expect(layout.dots.count == 8, "asking for eight dots must draw eight")
        #expect(layout.overflow == 3)
    }

    @Test func aQuietMacStillShowsDots() {
        // The bug this replaced: with nothing new, "show at most 4" drew nothing at all.
        let layout = StatusItemLayout.make(from: state(6, max: 4))
        #expect(layout.dots.count == 4)
        #expect(layout.overflow == 2)
    }

    @Test func raisingTheLimitShowsThemAll() {
        let layout = StatusItemLayout.make(from: state(11, unseen: [2, 5], max: 12))
        #expect(layout.dots.count == 11, "the limit is what decides, not a fixed 8")
        #expect(layout.overflow == 0)
    }

    @Test func hidingIdleRepositoriesCountsOnlyTheChangedOnes() {
        var quiet = state(20, unseen: Set(0..<9), max: 4)
        quiet.showIdleDots = false
        let layout = StatusItemLayout.make(from: quiet)
        #expect(layout.dots.count == 4)
        #expect(layout.overflow == 5, "9 changed, 4 drawn")
    }

    @Test func aLimitOfZeroIsNotAllowedToBlankTheBar() {
        let layout = StatusItemLayout.make(from: state(3, unseen: [0], max: 0))
        #expect(layout.dots.count == 1)
    }
}

@Suite("Preview fallback")
struct PreviewFallbackTests {
    func state(unseen: Int, style: MenuBarStyle) -> MenuBarState {
        var state = MenuBarState(repos: [RepoDot(id: UUID(), color: .red, unseen: unseen, hasError: false)])
        state.style = style
        return state
    }

    @Test func countWithNothingNewShowsOnlyTheGlyph() {
        let layout = StatusItemLayout.make(from: state(unseen: 0, style: .count))
        #expect(layout.showsOnlyGlyph, "the Settings preview falls back to the sample on this")
    }

    @Test func countWithNewCommitsHasSomethingToShow() {
        #expect(!StatusItemLayout.make(from: state(unseen: 3, style: .count)).showsOnlyGlyph)
    }

    @Test func iconOnlyIsBareUntilSomethingIsNew() {
        #expect(StatusItemLayout.make(from: state(unseen: 0, style: .iconOnly)).showsOnlyGlyph)
        #expect(!StatusItemLayout.make(from: state(unseen: 1, style: .iconOnly)).showsOnlyGlyph)
    }

    @Test func dotsAlwaysHaveSomethingToShow() {
        #expect(!StatusItemLayout.make(from: state(unseen: 0, style: .dots)).showsOnlyGlyph,
                "idle repositories still draw a dot")
    }

    @Test func theSampleIsNeverEmpty() {
        for style in MenuBarStyle.allCases {
            var sample = MenuBarState.sample
            sample.style = style
            #expect(!StatusItemLayout.make(from: sample).showsOnlyGlyph, "\(style) sample must render something")
        }
    }

    @Test func thePreviewSampleFollowsTheChosenStyle() {
        for style in MenuBarStyle.allCases {
            var settings = MenuBarState()
            settings.style = style
            let layout = StatusItemLayout.make(from: .sample(styledLike: settings))
            #expect(!layout.showsOnlyGlyph, "\(style) preview must show what the style does")
            switch style {
            case .dots: #expect(!layout.dots.isEmpty && layout.text == nil)
            case .count: #expect(layout.text != nil && layout.dots.isEmpty)
            case .iconOnly: #expect(layout.showsAttentionDot && layout.dots.isEmpty && layout.text == nil)
            }
        }
    }

    @Test func thePreviewSampleFollowsTheDotOptions() {
        var settings = MenuBarState()
        settings.style = .dots
        settings.idleDotStyle = .faded
        let faded = StatusItemLayout.make(from: .sample(styledLike: settings))
        #expect(faded.dots.contains { $0.fill == .faded })

        settings.idleDotStyle = .ring
        let ringed = StatusItemLayout.make(from: .sample(styledLike: settings))
        #expect(ringed.dots.contains { $0.fill == .ring })
        #expect(!ringed.dots.contains { $0.fill == .faded })

        settings.showIdleDots = false
        let changedOnly = StatusItemLayout.make(from: .sample(styledLike: settings))
        #expect(changedOnly.dots.count < ringed.dots.count, "hiding idle repositories must change the preview")
    }

    @Test func thePreviewSampleFollowsTheCountMode() {
        var settings = MenuBarState()
        settings.style = .count
        settings.badgeMode = .repositories
        let repositories = StatusItemLayout.make(from: .sample(styledLike: settings)).text

        settings.badgeMode = .commits
        let commits = StatusItemLayout.make(from: .sample(styledLike: settings)).text
        #expect(repositories != commits, "the sample must make the two count modes distinguishable")
    }
}
