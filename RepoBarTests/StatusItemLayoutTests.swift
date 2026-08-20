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
        #expect(layout.dots.map(\.fill) == [.filled, .faded, .error])
        #expect(layout.dots.map(\.color) == [.red, .blue, .green])
        #expect(layout.overflow == 0)
        #expect(layout.text == nil)

        state.idleDotStyle = .ring
        #expect(StatusItemLayout.make(from: state).dots[1].fill == .ring)

        state.showIdleDots = false
        let changedOnly = StatusItemLayout.make(from: state)
        #expect(changedOnly.dots.map(\.color) == [.red, .green], "idle repos hidden, errors kept")
    }

    @Test func dotsStyleCollapsesWhenManyRepos() {
        var specs: [(RepoColor, Int, Bool)] = []
        for index in 0..<12 { specs.append((RepoColor.allCases[index % 12], index.isMultiple(of: 2) ? 1 : 0, false)) }
        let state = MenuBarState(repos: dots(specs))
        let layout = StatusItemLayout.make(from: state)
        #expect(layout.dots.count == 6)
        #expect(layout.dots.allSatisfy { $0.fill == .filled })
        #expect(layout.overflow == 0)

        var allChanged = state
        allChanged.repos = dots(specs.map { ($0.0, 1, false) })
        let overflow = StatusItemLayout.make(from: allChanged)
        #expect(overflow.dots.count == 6)
        #expect(overflow.overflow == 6)
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
