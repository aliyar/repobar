import Foundation

public typealias RepoID = UUID

// MARK: - Watch configuration

public enum WatchMode: Codable, Sendable, Hashable {
    /// Follow the checked-out branch's upstream; fall back to the remote's default branch.
    case upstreamOfCurrentBranch
    /// Always watch this branch on the repo's remote, regardless of what is checked out.
    case remoteBranch(String)
}

public struct WatchedRef: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case upstream, remoteHead, lsRemoteSymref, heuristic, override
    }

    public var remote: String
    public var branch: String
    public var source: Source

    public init(remote: String, branch: String, source: Source) {
        self.remote = remote
        self.branch = branch
        self.source = source
    }

    public var trackingRef: String { "refs/remotes/\(remote)/\(branch)" }
    /// Key for per-ref acknowledgement maps.
    public var key: String { "\(remote)/\(branch)" }
}

// MARK: - Snapshot pieces

public enum HeadState: Codable, Sendable, Hashable {
    case branch(name: String, sha: String)
    case detached(sha: String)
    case unborn(name: String)

    public var branchName: String? {
        switch self {
        case .branch(let name, _), .unborn(let name): name
        case .detached: nil
        }
    }

    public var sha: String? {
        switch self {
        case .branch(_, let sha), .detached(let sha): sha
        case .unborn: nil
        }
    }

    public var isBranch: Bool {
        if case .branch = self { return true }
        return false
    }
}

public struct WorkingTreeState: Codable, Sendable, Hashable {
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0

    public init(staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0) {
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
    }

    /// Tracked changes only; untracked files do not block a fast-forward merge.
    public var isDirty: Bool { staged + unstaged + conflicted > 0 }
}

public struct BranchComparison: Codable, Sendable, Hashable {
    public var ahead: Int
    public var behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }
}

public struct IncomingCommit: Codable, Sendable, Hashable, Identifiable {
    public var sha: String
    public var shortSHA: String
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var subject: String
    public var isNew: Bool

    public var id: String { sha }

    public init(sha: String, shortSHA: String, authorName: String, authorEmail: String, authorDate: Date, subject: String, isNew: Bool = true) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
        self.isNew = isNew
    }
}

public enum NetworkMode: String, Codable, Sendable {
    case probedUnchanged
    case fetched
    case offlineLocalOnly
    case skippedBackoff
    case skippedPaused
    case notAttempted
}

/// One check's result. Persisted so the UI can show the last known state instantly at launch.
public struct RepoSnapshot: Codable, Sendable, Hashable {
    public var checkedAt: Date
    public var head: HeadState?
    public var upstream: WatchedRef?
    public var watched: WatchedRef?
    public var watchedTipSHA: String?
    public var comparison: BranchComparison?
    public var unseenCount: Int
    public var incoming: [IncomingCommit]
    public var workingTree: WorkingTreeState
    public var isShallow: Bool
    public var historyRewritten: Bool
    public var networkMode: NetworkMode
    public var remoteURL: String?
    public var web: WebRemote?
    /// Branches that exist on the watched remote, for the "Watch Branch" menu.
    public var remoteBranches: [String] = []
    public var error: RepoError?

    public init(
        checkedAt: Date,
        head: HeadState? = nil,
        upstream: WatchedRef? = nil,
        watched: WatchedRef? = nil,
        watchedTipSHA: String? = nil,
        comparison: BranchComparison? = nil,
        unseenCount: Int = 0,
        incoming: [IncomingCommit] = [],
        workingTree: WorkingTreeState = WorkingTreeState(),
        isShallow: Bool = false,
        historyRewritten: Bool = false,
        networkMode: NetworkMode = .notAttempted,
        remoteURL: String? = nil,
        web: WebRemote? = nil,
        remoteBranches: [String] = [],
        error: RepoError? = nil
    ) {
        self.checkedAt = checkedAt
        self.head = head
        self.upstream = upstream
        self.watched = watched
        self.watchedTipSHA = watchedTipSHA
        self.comparison = comparison
        self.unseenCount = unseenCount
        self.incoming = incoming
        self.workingTree = workingTree
        self.isShallow = isShallow
        self.historyRewritten = historyRewritten
        self.networkMode = networkMode
        self.remoteURL = remoteURL
        self.web = web
        self.remoteBranches = remoteBranches
        self.error = error
    }

    public var behind: Int { comparison?.behind ?? 0 }
    public var ahead: Int { comparison?.ahead ?? 0 }
    public var hasUnseen: Bool { unseenCount > 0 }

    // Hand-written like RepoRecord and RepoState: the synthesized decoder throws on a
    // key that a previously written state.json does not have, which would drop every
    // stored snapshot the first time a field is added.
    enum CodingKeys: String, CodingKey {
        case checkedAt, head, upstream, watched, watchedTipSHA, comparison, unseenCount, incoming
        case workingTree, isShallow, historyRewritten, networkMode, remoteURL, web, remoteBranches, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        head = try c.decodeIfPresent(HeadState.self, forKey: .head)
        upstream = try c.decodeIfPresent(WatchedRef.self, forKey: .upstream)
        watched = try c.decodeIfPresent(WatchedRef.self, forKey: .watched)
        watchedTipSHA = try c.decodeIfPresent(String.self, forKey: .watchedTipSHA)
        comparison = try c.decodeIfPresent(BranchComparison.self, forKey: .comparison)
        unseenCount = try c.decodeIfPresent(Int.self, forKey: .unseenCount) ?? 0
        incoming = try c.decodeIfPresent([IncomingCommit].self, forKey: .incoming) ?? []
        workingTree = try c.decodeIfPresent(WorkingTreeState.self, forKey: .workingTree) ?? WorkingTreeState()
        isShallow = try c.decodeIfPresent(Bool.self, forKey: .isShallow) ?? false
        historyRewritten = try c.decodeIfPresent(Bool.self, forKey: .historyRewritten) ?? false
        networkMode = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .notAttempted
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        web = try c.decodeIfPresent(WebRemote.self, forKey: .web)
        remoteBranches = try c.decodeIfPresent([String].self, forKey: .remoteBranches) ?? []
        error = try c.decodeIfPresent(RepoError.self, forKey: .error)
    }
}

// MARK: - Persistence records

/// User intent for one repository (rarely changes).
public struct RepoRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: RepoID
    /// Absolute top-level working tree path (normalized through `git rev-parse --show-toplevel`).
    public var path: String
    public var bookmark: Data?
    /// Shared `.git` dir for linked worktrees; key for fetch serialization.
    public var gitCommonDir: String
    public var displayName: String?
    /// Color identifier owned by the UI layer (e.g. "blue"); nil → assigned on first display.
    public var colorID: String?
    public var watch: WatchMode
    public var remoteOverride: String?
    public var webURLOverride: String?
    public var notificationsMuted: Bool
    /// Temporary silence; notifications resume by themselves at this date.
    public var mutedUntil: Date?
    public var includeUntracked: Bool
    /// Bundle id this repository was last opened with (UI layer); nil → the global default app.
    public var lastOpenedAppBundleID: String?
    public var addedAt: Date
    public var sortOrder: Int

    public init(
        id: RepoID = UUID(),
        path: String,
        bookmark: Data? = nil,
        gitCommonDir: String,
        displayName: String? = nil,
        colorID: String? = nil,
        watch: WatchMode = .upstreamOfCurrentBranch,
        remoteOverride: String? = nil,
        webURLOverride: String? = nil,
        notificationsMuted: Bool = false,
        mutedUntil: Date? = nil,
        includeUntracked: Bool = true,
        lastOpenedAppBundleID: String? = nil,
        addedAt: Date = Date(),
        sortOrder: Int = 0
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.gitCommonDir = gitCommonDir
        self.displayName = displayName
        self.colorID = colorID
        self.watch = watch
        self.remoteOverride = remoteOverride
        self.webURLOverride = webURLOverride
        self.notificationsMuted = notificationsMuted
        self.mutedUntil = mutedUntil
        self.includeUntracked = includeUntracked
        self.lastOpenedAppBundleID = lastOpenedAppBundleID
        self.addedAt = addedAt
        self.sortOrder = sortOrder
    }

    public var name: String { displayName ?? URL(fileURLWithPath: path).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Indefinitely muted, or still inside a temporary silence.
    public func isMuted(at date: Date = Date()) -> Bool {
        if notificationsMuted { return true }
        guard let mutedUntil else { return false }
        return date < mutedUntil
    }

    // Tolerate older files that lack newer keys.
    enum CodingKeys: String, CodingKey {
        case id, path, bookmark, gitCommonDir, displayName, colorID, watch, remoteOverride, webURLOverride
        case notificationsMuted, mutedUntil, includeUntracked, lastOpenedAppBundleID, addedAt, sortOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RepoID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        gitCommonDir = try c.decodeIfPresent(String.self, forKey: .gitCommonDir) ?? (path as NSString).appendingPathComponent(".git")
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        colorID = try c.decodeIfPresent(String.self, forKey: .colorID)
        watch = try c.decodeIfPresent(WatchMode.self, forKey: .watch) ?? .upstreamOfCurrentBranch
        remoteOverride = try c.decodeIfPresent(String.self, forKey: .remoteOverride)
        webURLOverride = try c.decodeIfPresent(String.self, forKey: .webURLOverride)
        notificationsMuted = try c.decodeIfPresent(Bool.self, forKey: .notificationsMuted) ?? false
        mutedUntil = try c.decodeIfPresent(Date.self, forKey: .mutedUntil)
        includeUntracked = try c.decodeIfPresent(Bool.self, forKey: .includeUntracked) ?? true
        lastOpenedAppBundleID = try c.decodeIfPresent(String.self, forKey: .lastOpenedAppBundleID)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

public struct CachedValue<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var value: Value
    public var resolvedAt: Date

    public init(value: Value, resolvedAt: Date = Date()) {
        self.value = value
        self.resolvedAt = resolvedAt
    }

    public func isFresh(maxAge: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(resolvedAt) < maxAge
    }
}

public enum FailureKind: String, Codable, Sendable, Hashable {
    /// Credentials / host keys / missing repo on the remote: back off exponentially.
    case auth
    /// Connectivity / timeouts / 5xx: short backoff, reachability gating does the rest.
    case network
    /// Lock conflicts: retry once quickly.
    case lock
    /// Not a repository, dubious ownership, git missing: wait for the user.
    case fatal
    /// Needs user action (diverged, dirty tree…).
    case user
}

/// Volatile per-repo cache (written after every check).
public struct RepoState: Codable, Sendable, Hashable {
    public var lastSeenSHA: [String: String] = [:]
    public var lastNotifiedSHA: [String: String] = [:]
    public var cachedDefaultBranch: [String: CachedValue<String>] = [:]
    public var cachedRemoteURL: CachedValue<String>?
    public var lastSnapshot: RepoSnapshot?
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var consecutiveFailures = 0
    public var lastFailureKind: FailureKind?
    public var backoffUntil: Date?
    /// When the branch first went ahead of its remote; cleared once it is pushed.
    public var aheadSince: Date?
    public var lastUnpushedReminderAt: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lastSeenSHA, lastNotifiedSHA, cachedDefaultBranch, cachedRemoteURL, lastSnapshot
        case lastAttemptAt, lastSuccessAt, consecutiveFailures, lastFailureKind, backoffUntil
        case aheadSince, lastUnpushedReminderAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSeenSHA = try c.decodeIfPresent([String: String].self, forKey: .lastSeenSHA) ?? [:]
        lastNotifiedSHA = try c.decodeIfPresent([String: String].self, forKey: .lastNotifiedSHA) ?? [:]
        cachedDefaultBranch = try c.decodeIfPresent([String: CachedValue<String>].self, forKey: .cachedDefaultBranch) ?? [:]
        cachedRemoteURL = try c.decodeIfPresent(CachedValue<String>.self, forKey: .cachedRemoteURL)
        lastSnapshot = try c.decodeIfPresent(RepoSnapshot.self, forKey: .lastSnapshot)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastSuccessAt = try c.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastFailureKind = try c.decodeIfPresent(FailureKind.self, forKey: .lastFailureKind)
        backoffUntil = try c.decodeIfPresent(Date.self, forKey: .backoffUntil)
        aheadSince = try c.decodeIfPresent(Date.self, forKey: .aheadSince)
        lastUnpushedReminderAt = try c.decodeIfPresent(Date.self, forKey: .lastUnpushedReminderAt)
    }
}

// MARK: - Validation

/// Output of `git rev-parse` at add time.
public struct RepoValidation: Sendable, Hashable {
    public var toplevel: String
    public var gitDir: String
    public var gitCommonDir: String
    public var isBare: Bool
    public var isShallow: Bool
    public var superprojectWorkingTree: String?

    public var isLinkedWorktree: Bool { gitDir != gitCommonDir }

    public init(toplevel: String, gitDir: String, gitCommonDir: String, isBare: Bool, isShallow: Bool, superprojectWorkingTree: String?) {
        self.toplevel = toplevel
        self.gitDir = gitDir
        self.gitCommonDir = gitCommonDir
        self.isBare = isBare
        self.isShallow = isShallow
        self.superprojectWorkingTree = superprojectWorkingTree
    }
}
