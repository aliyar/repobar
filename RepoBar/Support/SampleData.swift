import Foundation
import GitEngine

/// Realistic sample repositories for Xcode previews and generated screenshots.
enum SampleData {
    struct Repo {
        var name: String
        var color: RepoColor
        var branch: String
        var ahead = 0
        var behind = 0
        var unseen = 0
        var dirty = false
        var error: RepoError?
        var commits: [(String, String, TimeInterval)] = [] // subject, author, seconds ago
    }

    static let repos: [Repo] = [
        Repo(name: "website", color: .red, branch: "main", behind: 3, unseen: 3, commits: [
            ("Fix flaky retry logic in the sync worker", "Mia Chen", 5 * 60),
            ("Add dark mode to the settings page", "Tom Becker", 48 * 60),
            ("Bump dependencies", "Renovate Bot", 3 * 3600),
        ]),
        Repo(name: "api", color: .blue, branch: "feature/rate-limits", ahead: 2, behind: 1, unseen: 1, dirty: true, commits: [
            ("Migrate CI to macOS 15 runners", "Sara Lind", 26 * 3600),
        ]),
        Repo(name: "mobile-app", color: .green, branch: "main"),
        Repo(name: "design-system", color: .orange, branch: "main", error: .authFailed(.ssh)),
        Repo(name: "infra", color: .purple, branch: "main"),
    ]

    /// Deterministic pseudo-random 40-hex SHA for a seed string.
    static func sha(_ seed: String) -> String {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for byte in seed.utf8 { state = (state ^ UInt64(byte)) &* 0x100_0000_01B3 }
        var hex = ""
        while hex.count < 40 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            hex += String(state, radix: 16)
        }
        return String(hex.prefix(40))
    }

    /// Records + snapshots as the engine would emit them.
    static func make(now: Date = Date()) -> (records: [RepoRecord], snapshots: [RepoID: RepoSnapshot]) {
        var records: [RepoRecord] = []
        var snapshots: [RepoID: RepoSnapshot] = [:]
        for (index, repo) in repos.enumerated() {
            let record = RepoRecord(
                path: "/Users/you/Developer/\(repo.name)",
                gitCommonDir: "/Users/you/Developer/\(repo.name)/.git",
                colorID: repo.color.rawValue,
                addedAt: now.addingTimeInterval(-86400 * Double(index + 1)),
                sortOrder: index
            )
            let sha = Self.sha(repo.name)
            let incoming = repo.commits.enumerated().map { offset, commit in
                let commitSHA = Self.sha(repo.name + commit.0)
                return IncomingCommit(
                    sha: commitSHA,
                    shortSHA: String(commitSHA.prefix(7)),
                    authorName: commit.1,
                    authorEmail: "\(commit.1.lowercased().replacingOccurrences(of: " ", with: "."))@example.com",
                    authorDate: now.addingTimeInterval(-commit.2),
                    subject: commit.0,
                    isNew: offset < repo.unseen
                )
            }
            let watched = WatchedRef(remote: "origin", branch: repo.branch == "main" ? "main" : repo.branch, source: .upstream)
            let snapshot = RepoSnapshot(
                checkedAt: now.addingTimeInterval(-90),
                head: .branch(name: repo.branch, sha: sha),
                upstream: watched,
                watched: watched,
                watchedTipSHA: incoming.first?.sha ?? sha,
                comparison: BranchComparison(ahead: repo.ahead, behind: repo.behind),
                unseenCount: repo.unseen,
                incoming: incoming,
                workingTree: WorkingTreeState(staged: 0, unstaged: repo.dirty ? 2 : 0, untracked: 0, conflicted: 0),
                networkMode: repo.behind > 0 ? .fetched : .probedUnchanged,
                remoteURL: "git@github.com:example/\(repo.name).git",
                web: WebRemote.from(remote: "git@github.com:example/\(repo.name).git"),
                error: repo.error
            )
            records.append(record)
            snapshots[record.id] = snapshot
        }
        return (records, snapshots)
    }
}
