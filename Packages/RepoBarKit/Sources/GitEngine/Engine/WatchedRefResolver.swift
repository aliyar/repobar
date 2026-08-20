import Foundation

/// Resolves which remote branch to watch for a repository. See plan §5.1 step 4.
public struct WatchedRefResolver: Sendable {
    public struct Resolution: Sendable {
        /// HEAD's own upstream (remote branches only).
        public var upstream: WatchedRef?
        public var watched: WatchedRef?
        public var remote: String?
        /// SHA of `refs/remotes/<remote>/<branch>` if it exists locally.
        public var localTrackingSHA: String?
        public var error: RepoError?
        /// Default-branch cache entries to persist.
        public var cachedDefaultBranch: [String: CachedValue<String>]
    }

    public static let heuristicBranches = ["main", "master", "develop", "trunk"]
    public static let defaultBranchCacheAge: TimeInterval = 24 * 3600

    let git: GitClient

    public init(git: GitClient) {
        self.git = git
    }

    public func resolve(record: RepoRecord, head: HeadState, remotes: [String], state: RepoState, allowNetwork: Bool, now: Date) async throws -> Resolution {
        var resolution = Resolution(cachedDefaultBranch: state.cachedDefaultBranch)
        let repo = record.url

        // HEAD's upstream.
        if let branchName = head.branchName {
            let out = try await git.run(["for-each-ref", "--format=\(ForEachRefParser.format)", "refs/heads/\(branchName)"], in: repo)
            if let rec = ForEachRefParser.parse(out.stdoutText).first,
               let remoteName = rec.upstreamRemoteName, remoteName != ".",
               let remoteRef = rec.upstreamRemoteRef, remoteRef.hasPrefix("refs/heads/") {
                resolution.upstream = WatchedRef(remote: remoteName, branch: String(remoteRef.dropFirst("refs/heads/".count)), source: .upstream)
            }
        }

        // Remote selection.
        guard !remotes.isEmpty else {
            resolution.error = .noRemote
            return resolution
        }
        let remote: String
        if let override = record.remoteOverride, remotes.contains(override) {
            remote = override
        } else if let upstreamRemote = resolution.upstream?.remote, remotes.contains(upstreamRemote) {
            remote = upstreamRemote
        } else if remotes.contains("origin") {
            remote = "origin"
        } else if remotes.count == 1 {
            remote = remotes[0]
        } else {
            resolution.error = .ambiguousRemote(remotes)
            return resolution
        }
        resolution.remote = remote

        // Branch selection.
        var branchCandidates: [String] = []
        var watched: WatchedRef?
        switch record.watch {
        case .remoteBranch(let branch):
            watched = WatchedRef(remote: remote, branch: branch, source: .override)
        case .upstreamOfCurrentBranch:
            if let upstream = resolution.upstream, upstream.remote == remote {
                watched = upstream
            }
        }

        if watched == nil {
            branchCandidates = Self.heuristicBranches
        }
        var refsToQuery = ["refs/remotes/\(remote)/HEAD"]
        if let watched { refsToQuery.append(watched.trackingRef) }
        refsToQuery += branchCandidates.map { "refs/remotes/\(remote)/\($0)" }
        let refsOut = try await git.run(["for-each-ref", "--format=\(ForEachRefParser.format)"] + refsToQuery, in: repo)
        let refs = ForEachRefParser.parse(refsOut.stdoutText)
        func sha(of ref: String) -> String? { refs.first { $0.refname == ref }?.objectName }

        if watched == nil {
            // 1. origin/HEAD symref (offline)
            if let symref = refs.first(where: { $0.refname == "refs/remotes/\(remote)/HEAD" })?.symref,
               symref.hasPrefix("refs/remotes/\(remote)/") {
                watched = WatchedRef(remote: remote, branch: String(symref.dropFirst("refs/remotes/\(remote)/".count)), source: .remoteHead)
            }
            // 2. cached ls-remote --symref result
            if watched == nil, let cached = state.cachedDefaultBranch[remote], cached.isFresh(maxAge: Self.defaultBranchCacheAge, now: now) {
                watched = WatchedRef(remote: remote, branch: cached.value, source: .lsRemoteSymref)
            }
            // 3. ls-remote --symref (network)
            if watched == nil, allowNetwork {
                let out = try await git.output(["ls-remote", "--symref", "-q", "--", remote, "HEAD"], in: repo, timeout: GitClient.probeTimeout, network: true)
                if out.exitCode == 0, let branch = LsRemoteParser.parseSymrefHead(out.stdoutText) {
                    watched = WatchedRef(remote: remote, branch: branch, source: .lsRemoteSymref)
                    resolution.cachedDefaultBranch[remote] = CachedValue(value: branch, resolvedAt: now)
                } else if out.exitCode != 0 {
                    throw GitError.failed(exitCode: out.exitCode, stderr: out.stderr, arguments: ["ls-remote", "--symref"])
                }
            }
            // 4. heuristic: first existing tracking ref
            if watched == nil {
                for candidate in Self.heuristicBranches where sha(of: "refs/remotes/\(remote)/\(candidate)") != nil {
                    watched = WatchedRef(remote: remote, branch: candidate, source: .heuristic)
                    break
                }
            }
        }

        guard let watched else {
            resolution.error = .noDefaultBranch
            return resolution
        }
        resolution.watched = watched
        if let known = sha(of: watched.trackingRef) {
            resolution.localTrackingSHA = known
        } else if watched.source == .lsRemoteSymref || watched.source == .override {
            // Not part of the first query; look it up now.
            let out = try await git.run(["for-each-ref", "--format=\(ForEachRefParser.format)", watched.trackingRef], in: repo)
            resolution.localTrackingSHA = ForEachRefParser.parse(out.stdoutText).first?.objectName
        }
        return resolution
    }
}
