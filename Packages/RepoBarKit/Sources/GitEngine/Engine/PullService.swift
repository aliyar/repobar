import Foundation

public enum PullRefusal: Error, Sendable, Hashable {
    case noSnapshot
    case detachedHead
    case unbornBranch
    case notWatchingUpstream
    case nothingToPull
    case diverged
    case workingTreeDirty
    case headMoved
    case operationInProgress(String)

    public var message: String {
        switch self {
        case .noSnapshot: "Check the repository first."
        case .detachedHead: "HEAD is detached — check out a branch first."
        case .unbornBranch: "The current branch has no commits yet."
        case .notWatchingUpstream: "Pull only works for the checked-out branch's upstream."
        case .nothingToPull: "Already up to date."
        case .diverged: "Local branch has diverged — pull manually (merge or rebase)."
        case .workingTreeDirty: "Working tree has changes — commit or stash first."
        case .headMoved: "The checked-out branch changed since the last check — check again first."
        case .operationInProgress(let what): "A \(what) is in progress — finish or abort it first."
        }
    }
}

public struct PullResult: Sendable, Hashable {
    public var fromSHA: String
    public var toSHA: String
    public var commitCount: Int
}

/// Fast-forward-only "pull": a local `merge --ff-only` onto the already-fetched tracking ref (plan §5.3).
public struct PullService: Sendable {
    public let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    static let inProgressMarkers: [(String, String)] = [
        ("MERGE_HEAD", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick"), ("REVERT_HEAD", "revert"),
        ("BISECT_LOG", "bisect"), ("rebase-merge", "rebase"), ("rebase-apply", "rebase"),
    ]

    /// Pure precondition check (no git calls).
    public static func preflight(snapshot: RepoSnapshot?) throws(PullRefusal) {
        guard let snapshot else { throw .noSnapshot }
        switch snapshot.head {
        case .detached?: throw .detachedHead
        case .unborn?: throw .unbornBranch
        case .branch?: break
        case nil: throw .noSnapshot
        }
        guard let watched = snapshot.watched, let upstream = snapshot.upstream, watched.key == upstream.key else { throw .notWatchingUpstream }
        guard let comparison = snapshot.comparison, comparison.behind > 0 else { throw .nothingToPull }
        guard comparison.ahead == 0 else { throw .diverged }
        guard !snapshot.workingTree.isDirty else { throw .workingTreeDirty }
    }

    public func pull(record: RepoRecord, snapshot: RepoSnapshot?) async throws -> PullResult {
        try Self.preflight(snapshot: snapshot)
        guard let snapshot, let watched = snapshot.watched,
              case .branch(let branch, let from)? = snapshot.head else { throw PullRefusal.noSnapshot }
        let repo = record.url

        // The snapshot is as old as the last check, and the merge below fast-forwards
        // whatever HEAD points at *now*. Re-read it first: `git switch -c topic` keeps the
        // same SHA, so only the branch name reveals that we would move the wrong ref.
        let out = try await git.run(["rev-parse", "--path-format=absolute", "--git-dir", "HEAD", "--abbrev-ref", "HEAD"], in: repo)
        let lines = out.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 3 else { throw PullRefusal.noSnapshot }
        guard lines[1] == from, lines[2] == branch else { throw PullRefusal.headMoved }
        let gitDir = URL(fileURLWithPath: lines[0], isDirectory: true)
        for (marker, name) in Self.inProgressMarkers where FileManager.default.fileExists(atPath: gitDir.appendingPathComponent(marker).path) {
            throw PullRefusal.operationInProgress(name)
        }

        try await git.run(["merge", "--ff-only", "--no-edit", "--no-stat", "--", watched.trackingRef], in: repo, timeout: GitClient.mergeTimeout)
        let headOut = try await git.run(["rev-parse", "HEAD"], in: repo)
        let to = headOut.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return PullResult(fromSHA: from, toSHA: to, commitCount: snapshot.behind)
    }
}
