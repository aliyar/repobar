import Foundation
import os

public struct CheckOptions: Sendable {
    public var now: Date
    public var allowNetwork: Bool
    /// Reported as `networkMode` when `allowNetwork` is false.
    public var skippedReason: NetworkMode
    public var probeBeforeFetch: Bool
    public var pruneOnFetch: Bool
    public var fetchTimeout: Duration
    public var maxIncoming: Int

    public init(
        now: Date = Date(),
        allowNetwork: Bool = true,
        skippedReason: NetworkMode = .notAttempted,
        probeBeforeFetch: Bool = true,
        pruneOnFetch: Bool = false,
        fetchTimeout: Duration = GitClient.fetchTimeout,
        maxIncoming: Int = 200
    ) {
        self.now = now
        self.allowNetwork = allowNetwork
        self.skippedReason = skippedReason
        self.probeBeforeFetch = probeBeforeFetch
        self.pruneOnFetch = pruneOnFetch
        self.fetchTimeout = fetchTimeout
        self.maxIncoming = maxIncoming
    }
}

public struct CheckOutcome: Sendable {
    public var snapshot: RepoSnapshot
    /// State with updated acknowledgement/caches (failure counters are the engine's job).
    public var state: RepoState
}

/// The per-repository check pipeline (plan §5.1). Stateless; everything it learns goes into the outcome.
public struct RepoChecker: Sendable {
    public let git: GitClient
    private let logger = Logger(subsystem: "com.aliyar.RepoBar", category: "engine")

    public init(git: GitClient) {
        self.git = git
    }

    // MARK: Validation (add time)

    public func validate(path: URL) async throws -> RepoValidation {
        // `--show-toplevel` fails inside bare repositories, so ask about bareness first.
        let bareOut = try await git.run(["rev-parse", "--is-bare-repository"], in: path)
        if bareOut.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true" {
            let dirOut = try await git.run(["rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"], in: path)
            let lines = dirOut.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
            return RepoValidation(toplevel: path.path, gitDir: lines.first ?? path.path, gitCommonDir: lines.last ?? path.path, isBare: true, isShallow: false, superprojectWorkingTree: nil)
        }
        let out = try await git.run(["rev-parse"] + RevParseParser.validationFlags, in: path)
        return try RevParseParser.parseValidation(out.stdoutText)
    }

    /// Directories directly inside `folder` that contain a `.git` entry (file or directory).
    public static func discoverRepositories(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(".git").path) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Check

    public func check(_ record: RepoRecord, state: RepoState, options: CheckOptions) async -> CheckOutcome {
        var snapshot = RepoSnapshot(checkedAt: options.now, networkMode: options.allowNetwork ? .notAttempted : options.skippedReason)

        // 1. Preflight
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.path, isDirectory: &isDirectory), isDirectory.boolValue,
              access(record.path, R_OK) == 0 else {
            snapshot.error = .repoMissing
            return CheckOutcome(snapshot: snapshot, state: state)
        }

        // A user-configured `core.sshCommand` must not be overridden by our GIT_SSH_COMMAND.
        var client = git
        if options.allowNetwork, client.networkEnvironment["GIT_SSH_COMMAND"] != client.environment["GIT_SSH_COMMAND"],
           let out = try? await client.output(["config", "--get", "core.sshCommand"], in: record.url), out.exitCode == 0 {
            client.networkEnvironment = client.environment
        }
        return await RepoChecker(git: client).performCheck(record, state: state, snapshot: snapshot, options: options)
    }

    private func performCheck(_ record: RepoRecord, state: RepoState, snapshot initial: RepoSnapshot, options: CheckOptions) async -> CheckOutcome {
        var state = state
        var snapshot = initial
        let repo = record.url

        do {
            // 2. Local status (one invocation) + shallow flag
            let statusArgs = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=\(record.includeUntracked ? "normal" : "no")"]
            let statusOut = try await runRetryingLocks(statusArgs, in: repo)
            let status = try StatusV2Parser.parse(statusOut.stdout)
            snapshot.head = status.head
            snapshot.workingTree = status.workingTree
            let shallowOut = try await git.run(["rev-parse", "--is-shallow-repository"], in: repo)
            snapshot.isShallow = shallowOut.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"

            // 3. Remotes + watched ref
            let remotesOut = try await git.run(["remote"], in: repo)
            let remotes = remotesOut.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
            let resolver = WatchedRefResolver(git: git)
            let resolution = try await resolver.resolve(record: record, head: status.head, remotes: remotes, state: state, allowNetwork: options.allowNetwork, now: options.now)
            state.cachedDefaultBranch = resolution.cachedDefaultBranch
            snapshot.upstream = resolution.upstream
            snapshot.watched = resolution.watched
            snapshot.remoteBranches = resolution.remoteBranches
            if let error = resolution.error {
                snapshot.error = error
                return CheckOutcome(snapshot: snapshot, state: state)
            }
            guard let watched = resolution.watched, let remote = resolution.remote else {
                snapshot.error = .noDefaultBranch
                return CheckOutcome(snapshot: snapshot, state: state)
            }

            // 4. Web URL (cached daily)
            if let cached = state.cachedRemoteURL, cached.isFresh(maxAge: 24 * 3600, now: options.now) {
                snapshot.remoteURL = cached.value
            } else {
                let urlOut = try await git.output(["ls-remote", "--get-url", "--", remote], in: repo)
                if urlOut.exitCode == 0 {
                    let url = urlOut.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                    snapshot.remoteURL = url
                    state.cachedRemoteURL = CachedValue(value: url, resolvedAt: options.now)
                }
            }
            if let remoteURL = snapshot.remoteURL {
                snapshot.web = WebRemote.from(remote: remoteURL, override: record.webURLOverride)
            }

            // 5. Network: probe, then fetch only when the tip moved
            var tipSHA = resolution.localTrackingSHA
            if options.allowNetwork {
                var needsFetch = true
                if options.probeBeforeFetch {
                    let probe = try await git.output(["ls-remote", "--heads", "--exit-code", "-q", "--", remote, "refs/heads/\(watched.branch)"], in: repo, timeout: GitClient.probeTimeout, network: true)
                    if probe.exitCode == 2 {
                        snapshot.error = .remoteRefNotFound(branch: watched.branch)
                        snapshot.networkMode = .probedUnchanged
                        return CheckOutcome(snapshot: snapshot, state: state)
                    }
                    guard probe.exitCode == 0 else {
                        throw GitError.failed(exitCode: probe.exitCode, stderr: probe.stderr, arguments: ["ls-remote"])
                    }
                    let remoteSHA = LsRemoteParser.parseRefs(probe.stdoutText).first?.sha
                    if let remoteSHA, remoteSHA == tipSHA {
                        needsFetch = false
                        snapshot.networkMode = .probedUnchanged
                    }
                }
                if needsFetch {
                    var args = ["fetch"]
                    if git.installation.supportsFetchPorcelain { args.append("--porcelain") }
                    args += ["--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules"]
                    if options.pruneOnFetch { args.append("--prune") }
                    args += ["--", remote]
                    _ = try await runRetryingLocks(args, in: repo, timeout: options.fetchTimeout, network: true)
                    snapshot.networkMode = .fetched
                    let refOut = try await git.run(["for-each-ref", "--format=\(ForEachRefParser.format)", watched.trackingRef], in: repo)
                    tipSHA = ForEachRefParser.parse(refOut.stdoutText).first?.objectName
                }
            }
            snapshot.watchedTipSHA = tipSHA

            guard let tipSHA else {
                // Never fetched and no network yet: nothing more to compute.
                return CheckOutcome(snapshot: snapshot, state: state)
            }

            // 6. HEAD vs watched
            let upstreamMode: Bool = {
                if case .upstreamOfCurrentBranch = record.watch { return true }
                return false
            }()
            let headSHA = status.head.sha
            if let headSHA {
                let out = try await git.run(["rev-list", "--left-right", "--count", "\(headSHA)...\(tipSHA)", "--"], in: repo)
                let counts = try RevListParser.parseLeftRightCount(out.stdoutText)
                snapshot.comparison = BranchComparison(ahead: counts.left, behind: counts.right)
            }

            // 7. Acknowledgement
            let key = watched.key
            let previousLastSeen = state.lastSeenSHA[key]
            var lastSeen: String
            if let previousLastSeen {
                lastSeen = previousLastSeen
            } else {
                var mergeBase: String?
                if upstreamMode, let headSHA {
                    let out = try await git.output(["merge-base", headSHA, tipSHA], in: repo)
                    if out.exitCode == 0 { mergeBase = out.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                lastSeen = AcknowledgementRules.initialLastSeen(upstreamMode: upstreamMode, mergeBase: mergeBase, tip: tipSHA)
            }
            var leftRight: (left: Int, right: Int)?
            let lrOut = try await git.output(["rev-list", "--left-right", "--count", "\(lastSeen)...\(tipSHA)", "--"], in: repo)
            if lrOut.exitCode == 0 { leftRight = try? RevListParser.parseLeftRightCount(lrOut.stdoutText) }
            let ack = AcknowledgementRules.apply(lastSeen: lastSeen, tip: tipSHA, leftRight: leftRight, upstreamMode: upstreamMode, behind: snapshot.comparison?.behind)
            state.lastSeenSHA[key] = ack.lastSeen
            snapshot.unseenCount = ack.unseen
            snapshot.historyRewritten = ack.historyRewritten
            lastSeen = ack.lastSeen

            // 8. Incoming commits
            snapshot.incoming = try await incomingCommits(
                in: repo, tip: tipSHA, headSHA: upstreamMode ? headSHA : nil,
                lastSeen: lastSeen, unseen: ack.unseen, rewritten: ack.historyRewritten, limit: options.maxIncoming
            )
        } catch let error as GitError {
            snapshot.error = error.repoError
            logger.error("check failed for \(record.name, privacy: .public): \(String(describing: error), privacy: .public)")
        } catch let error as ParseError {
            snapshot.error = .unknown("Could not parse git output (\(error))")
        } catch is CancellationError {
            snapshot.error = nil
            snapshot.networkMode = .notAttempted
        } catch {
            snapshot.error = .unknown(error.localizedDescription)
        }
        return CheckOutcome(snapshot: snapshot, state: state)
    }

    // MARK: Helpers

    private func incomingCommits(in repo: URL, tip: String, headSHA: String?, lastSeen: String, unseen: Int, rewritten: Bool, limit: Int) async throws -> [IncomingCommit] {
        let base = ["log", "-z", "--no-color", "--format=\(LogParser.format)"]
        if rewritten {
            let out = try await git.run(base + ["--max-count=10", tip, "--"], in: repo)
            return try LogParser.parse(out.stdout).map { var c = $0; c.isNew = false; return c }
        }
        if let headSHA {
            // Commits HEAD doesn't have; "new" = the unseen subset.
            let out = try await git.run(base + ["--max-count=\(limit)", "\(headSHA)..\(tip)", "--"], in: repo)
            var commits = try LogParser.parse(out.stdout)
            let newSet: Set<String>
            if unseen > 0 {
                let newOut = try await git.run(["log", "-z", "--format=%H", "--max-count=\(limit)", "\(lastSeen)..\(tip)", "--"], in: repo)
                newSet = Set(newOut.stdoutText.split(separator: "\0").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            } else {
                newSet = []
            }
            for index in commits.indices { commits[index].isNew = newSet.contains(commits[index].sha) }
            return commits
        }
        if unseen > 0 {
            let out = try await git.run(base + ["--max-count=\(limit)", "\(lastSeen)..\(tip)", "--"], in: repo)
            return try LogParser.parse(out.stdout)
        }
        // Nothing new (override branch or unborn HEAD): show recent history as context.
        let out = try await git.run(base + ["--max-count=10", tip, "--"], in: repo)
        return try LogParser.parse(out.stdout).map { var c = $0; c.isNew = false; return c }
    }

    /// Retries once after 2 s when git reports a lock conflict (another git process running).
    private func runRetryingLocks(_ arguments: [String], in repo: URL, timeout: Duration? = nil, network: Bool = false) async throws -> GitOutput {
        do {
            return try await git.run(arguments, in: repo, timeout: timeout, network: network)
        } catch let error as GitError {
            if case .failed(_, let stderr, _) = error, GitErrorClassifier.classify(stderr: stderr) == .lockConflict {
                logger.notice("lock conflict, retrying once: \(arguments.first ?? "", privacy: .public)")
                try await Task.sleep(for: .seconds(2))
                return try await git.run(arguments, in: repo, timeout: timeout, network: network)
            }
            throw error
        }
    }
}
