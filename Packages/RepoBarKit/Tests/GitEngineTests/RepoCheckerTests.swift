import Foundation
import Testing
@testable import GitEngine

@Suite("RepoChecker (integration)", .timeLimit(.minutes(2)))
struct RepoCheckerTests {
    @Test func detectsIncomingCommitAndFetchesOnlyWhenNeeded() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)

        // Fresh repo, nothing new: probe says unchanged → no fetch.
        fx.runner.reset()
        let first = await fx.check(record)
        #expect(first.snapshot.error == nil)
        #expect(first.snapshot.networkMode == .probedUnchanged)
        #expect(first.snapshot.comparison == BranchComparison(ahead: 0, behind: 0))
        #expect(first.snapshot.unseenCount == 0)
        #expect(first.snapshot.watched?.key == "origin/main")
        #expect(first.snapshot.upstream?.source == .upstream)
        #expect(!fx.runner.gitSubcommands.contains("fetch"), "no fetch when the probe matches: \(fx.runner.gitSubcommands)")
        #expect(first.snapshot.web == nil, "file remotes have no web URL")

        // B pushes a commit → A is behind by one, fetched, one unseen commit.
        let sha = try await fx.commit(in: b, file: "feature.txt", content: "hello\n", message: "Add feature")
        try await fx.push(in: b)
        fx.runner.reset()
        let second = await fx.check(record, state: first.state)
        #expect(second.snapshot.error == nil)
        #expect(second.snapshot.networkMode == .fetched)
        #expect(fx.runner.gitSubcommands.contains("fetch"))
        #expect(second.snapshot.comparison == BranchComparison(ahead: 0, behind: 1))
        #expect(second.snapshot.unseenCount == 1)
        #expect(second.snapshot.watchedTipSHA == sha)
        #expect(second.snapshot.incoming.count == 1)
        #expect(second.snapshot.incoming.first?.sha == sha)
        #expect(second.snapshot.incoming.first?.subject == "Add feature")
        #expect(second.snapshot.incoming.first?.authorName == "Test")
        #expect(second.snapshot.incoming.first?.isNew == true)

        // Third check: nothing changed → probe short-circuits again, unseen stays 1.
        fx.runner.reset()
        let third = await fx.check(record, state: second.state)
        #expect(third.snapshot.networkMode == .probedUnchanged)
        #expect(third.snapshot.unseenCount == 1)
        #expect(!fx.runner.gitSubcommands.contains("fetch"))
    }

    @Test func markSeenClearsUnseenButKeepsBehind() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)
        try await fx.commit(in: b, file: "1.txt", content: "1", message: "one")
        let tip = try await fx.commit(in: b, file: "2.txt", content: "2", message: "two")
        try await fx.push(in: b)

        let outcome = await fx.check(record)
        #expect(outcome.snapshot.behind == 2)
        #expect(outcome.snapshot.unseenCount == 2)

        // Mark as seen = lastSeen := tip.
        var state = outcome.state
        state.lastSeenSHA["origin/main"] = tip
        let seen = await fx.check(record, state: state)
        #expect(seen.snapshot.behind == 2)
        #expect(seen.snapshot.unseenCount == 0)
        #expect(seen.snapshot.incoming.count == 2)
        #expect(seen.snapshot.incoming.allSatisfy { !$0.isNew })

        // A new push makes exactly one commit unseen again.
        try await fx.commit(in: b, file: "3.txt", content: "3", message: "three")
        try await fx.push(in: b)
        let again = await fx.check(record, state: seen.state)
        #expect(again.snapshot.behind == 3)
        #expect(again.snapshot.unseenCount == 1)
        #expect(again.snapshot.incoming.filter(\.isNew).count == 1)
    }

    @Test func alreadyBehindRepoLightsUpOnFirstCheck() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        try await fx.commit(in: b, file: "x.txt", content: "x", message: "x")
        try await fx.push(in: b)
        // First ever check of A (no lastSeen): merge-base start → the commit counts as unseen.
        let record = try await fx.record(for: a)
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.behind == 1)
        #expect(outcome.snapshot.unseenCount == 1)
    }

    @Test func aheadAndDiverged() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)

        try await fx.commit(in: a, file: "local.txt", content: "l", message: "local work")
        let ahead = await fx.check(record)
        #expect(ahead.snapshot.comparison == BranchComparison(ahead: 1, behind: 0))
        #expect(ahead.snapshot.unseenCount == 0)

        try await fx.commit(in: b, file: "remote.txt", content: "r", message: "remote work")
        try await fx.push(in: b)
        let diverged = await fx.check(record, state: ahead.state)
        #expect(diverged.snapshot.comparison == BranchComparison(ahead: 1, behind: 1))
        #expect(diverged.snapshot.unseenCount == 1)
    }

    @Test func workingTreeStates() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let record = try await fx.record(for: a)

        try "changed\n".write(to: a.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let unstaged = await fx.check(record)
        #expect(unstaged.snapshot.workingTree == WorkingTreeState(staged: 0, unstaged: 1, untracked: 0, conflicted: 0))
        #expect(unstaged.snapshot.workingTree.isDirty)

        try await fx.sh(["add", "README.md"], in: a)
        try "new\n".write(to: a.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let staged = await fx.check(record)
        #expect(staged.snapshot.workingTree == WorkingTreeState(staged: 1, unstaged: 0, untracked: 1, conflicted: 0))

        var noUntracked = record
        noUntracked.includeUntracked = false
        let hidden = await fx.check(noUntracked)
        #expect(hidden.snapshot.workingTree.untracked == 0)
    }

    @Test func branchWithoutUpstreamFallsBackToRemoteHead() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        try await fx.sh(["checkout", "-q", "-b", "feature"], in: a)
        let record = try await fx.record(for: a)

        let outcome = await fx.check(record)
        #expect(outcome.snapshot.head == .branch(name: "feature", sha: try await fx.head(of: a)))
        #expect(outcome.snapshot.upstream == nil)
        #expect(outcome.snapshot.watched == WatchedRef(remote: "origin", branch: "main", source: .remoteHead))
        #expect(outcome.snapshot.behind == 0)

        try await fx.commit(in: b, file: "m.txt", content: "m", message: "on main")
        try await fx.push(in: b)
        let after = await fx.check(record, state: outcome.state)
        #expect(after.snapshot.behind == 1)
        #expect(after.snapshot.unseenCount == 1)
        #expect(after.snapshot.incoming.first?.subject == "on main")
    }

    @Test func repoWithoutRemoteHeadUsesLsRemoteSymref() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = fx.directory("A")
        try await fx.sh(["init", "-q", "--initial-branch=work", a.path])
        try await fx.sh(["remote", "add", "origin", remote.path], in: a)
        let record = try await fx.record(for: a)

        let outcome = await fx.check(record)
        #expect(outcome.snapshot.error == nil)
        #expect(outcome.snapshot.head == .unborn(name: "work"))
        #expect(outcome.snapshot.watched == WatchedRef(remote: "origin", branch: "main", source: .lsRemoteSymref))
        #expect(outcome.state.cachedDefaultBranch["origin"]?.value == "main")
        #expect(outcome.snapshot.networkMode == .fetched)
        #expect(outcome.snapshot.comparison == nil, "unborn HEAD has nothing to compare")
        #expect(outcome.snapshot.incoming.count == 1, "recent history shown as context")
        #expect(outcome.snapshot.incoming.first?.isNew == false)

        // Second run uses the cache and needs no symref lookup.
        fx.runner.reset()
        let second = await fx.check(record, state: outcome.state)
        #expect(second.snapshot.watched?.source == .lsRemoteSymref)
        #expect(!fx.runner.invocations.contains { $0.contains("--symref") })
    }

    @Test func detachedHead() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        try await fx.sh(["checkout", "-q", "--detach"], in: a)
        let record = try await fx.record(for: a)
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.error == nil)
        if case .detached = outcome.snapshot.head {} else { Issue.record("expected detached head, got \(String(describing: outcome.snapshot.head))") }
        #expect(outcome.snapshot.watched?.branch == "main")
    }

    @Test func forcePushIsReportedAsRewrittenHistory() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)
        try await fx.commit(in: b, file: "f.txt", content: "1", message: "first version")
        try await fx.push(in: b)
        let before = await fx.check(record)
        #expect(before.snapshot.unseenCount == 1)
        // The user acknowledges "first version"; then B rewrites it.
        var acknowledged = before.state
        acknowledged.lastSeenSHA["origin/main"] = before.snapshot.watchedTipSHA

        try await fx.sh(["commit", "-q", "--amend", "-m", "rewritten"], in: b)
        try await fx.push(in: b, force: true)
        let after = await fx.check(record, state: acknowledged)
        #expect(after.snapshot.historyRewritten)
        #expect(after.snapshot.unseenCount == 0)
        #expect(after.state.lastSeenSHA["origin/main"] == after.snapshot.watchedTipSHA)
        #expect(after.snapshot.incoming.allSatisfy { !$0.isNew })
    }

    @Test func overrideBranchIsWatchedRegardlessOfHead() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let b = try await fx.clone(remote, as: "B")
        try await fx.sh(["checkout", "-q", "-b", "release"], in: b)
        try await fx.commit(in: b, file: "r.txt", content: "r", message: "release 1")
        try await fx.push(in: b, "release")
        let a = try await fx.clone(remote, as: "A") // on main
        let record = try await fx.record(for: a, watch: .remoteBranch("release"))

        let first = await fx.check(record)
        #expect(first.snapshot.error == nil)
        #expect(first.snapshot.watched == WatchedRef(remote: "origin", branch: "release", source: .override))
        #expect(first.snapshot.unseenCount == 0, "override branches start clean")
        #expect(first.snapshot.comparison?.behind == 1, "HEAD (main) vs release")

        try await fx.commit(in: b, file: "r2.txt", content: "r2", message: "release 2")
        try await fx.push(in: b, "release")
        let second = await fx.check(record, state: first.state)
        #expect(second.snapshot.unseenCount == 1)
        #expect(second.snapshot.incoming.count == 1)
        #expect(second.snapshot.incoming.first?.subject == "release 2")
    }

    @Test func missingPathNoRemoteAndRefNotFound() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let record = try await fx.record(for: a)

        try FileManager.default.removeItem(at: a)
        let missing = await fx.check(record)
        #expect(missing.snapshot.error == .repoMissing)

        let lonely = fx.directory("lonely")
        try await fx.sh(["init", "-q", lonely.path])
        let lonelyRecord = try await fx.record(for: lonely)
        let noRemote = await fx.check(lonelyRecord)
        #expect(noRemote.snapshot.error == .noRemote)
        #expect(noRemote.snapshot.head != nil, "local info is still reported")

        let c = try await fx.clone(remote, as: "C")
        let ghost = try await fx.record(for: c, watch: .remoteBranch("does-not-exist"))
        let notFound = await fx.check(ghost)
        #expect(notFound.snapshot.error == .remoteRefNotFound(branch: "does-not-exist"))
    }

    @Test func offlineModeSkipsNetworkButReportsLocalState() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let record = try await fx.record(for: a)
        fx.runner.reset()
        let outcome = await fx.check(record, options: CheckOptions(allowNetwork: false, skippedReason: .offlineLocalOnly))
        #expect(outcome.snapshot.error == nil)
        #expect(outcome.snapshot.networkMode == .offlineLocalOnly)
        #expect(outcome.snapshot.comparison == BranchComparison(ahead: 0, behind: 0))
        #expect(!fx.runner.gitSubcommands.contains("fetch"))
        #expect(!fx.runner.gitSubcommands.contains("ls-remote") || fx.runner.invocations.contains { $0.contains("--get-url") })
    }

    @Test func validationRejectsBareAndNormalizesSubdirectories() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let checker = RepoChecker(git: fx.git)
        let bare = try await checker.validate(path: remote)
        #expect(bare.isBare)

        let a = try await fx.clone(remote, as: "A")
        let sub = a.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let validation = try await checker.validate(path: sub)
        #expect(URL(fileURLWithPath: validation.toplevel).standardizedFileURL.resolvingSymlinksInPath() == a.standardizedFileURL.resolvingSymlinksInPath())
        #expect(!validation.isLinkedWorktree)
        #expect(validation.superprojectWorkingTree == nil)

        let worktree = fx.directory("A-wt")
        try await fx.sh(["worktree", "add", "-q", "--detach", worktree.path], in: a)
        let wt = try await checker.validate(path: worktree)
        #expect(wt.isLinkedWorktree)
        #expect(URL(fileURLWithPath: wt.gitCommonDir).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: validation.gitCommonDir).standardizedFileURL.resolvingSymlinksInPath())

        await #expect(throws: GitError.self) {
            _ = try await checker.validate(path: fx.directory("not-a-repo-\(UUID().uuidString)"))
        }
    }

    @Test func discoversRepositoriesOneLevelDeep() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let folder = fx.directory("Projects")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plain"), withIntermediateDirectories: true)
        _ = try await fx.clone(remote, as: "Projects/one")
        _ = try await fx.clone(remote, as: "Projects/two")
        let found = RepoChecker.discoverRepositories(in: folder)
        #expect(found.map(\.lastPathComponent) == ["one", "two"])
    }

    @Test func shallowCloneIsFlagged() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let b = try await fx.clone(remote, as: "B")
        try await fx.commit(in: b, file: "2.txt", content: "2", message: "second")
        try await fx.push(in: b)
        let shallow = fx.directory("shallow")
        try await fx.sh(["clone", "-q", "--depth", "1", "file://\(remote.path)", shallow.path])
        let record = try await fx.record(for: shallow)
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.isShallow)
        #expect(outcome.snapshot.error == nil)
    }

    @Test func lockConflictIsClassifiedAfterOneRetry() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)
        try await fx.commit(in: b, file: "l.txt", content: "l", message: "lock me")
        try await fx.push(in: b)
        // Hold the tracking ref's lock so fetch cannot update it.
        let lock = a.appendingPathComponent(".git/refs/remotes/origin/main.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: lock)
        fx.runner.reset()
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.error == .lockConflict)
        #expect(fx.runner.gitSubcommands.filter { $0 == "fetch" }.count == 2, "one retry")
    }

    @Test func timeoutIsReported() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let record = try await fx.record(for: a)
        // A fake git that sleeps for every command.
        let fake = fx.directory("bin").appendingPathComponent("git")
        try FileManager.default.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nsleep 10\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let installation = GitInstallation(url: fake, version: "9.9.9", major: 9, minor: 9, patch: 9)
        var client = GitClient(installation: installation, runner: FoundationProcessRunner(), environment: fx.environment)
        client.defaultTimeout = .milliseconds(400)
        let checker = RepoChecker(git: client)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await checker.check(record, state: RepoState(), options: CheckOptions())
        #expect(outcome.snapshot.error == .timeout(seconds: 0))
        #expect(clock.now - start < .seconds(5))
    }
}

@Suite("RepoChecker ssh config")
struct RepoCheckerSSHConfigTests {
    @Test func userSSHCommandIsRespected() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let record = try await fx.record(for: a)
        // Client with a distinct network environment (as production builds it).
        var network = fx.environment
        network["GIT_SSH_COMMAND"] = GitEnvironment.sshBatchCommand
        let client = GitClient(installation: fx.installation, runner: fx.runner, environment: fx.environment, networkEnvironment: network)
        try await fx.sh(["config", "core.sshCommand", "ssh -i /tmp/special_key"], in: a)
        let outcome = await RepoChecker(git: client).check(record, state: RepoState(), options: CheckOptions())
        #expect(outcome.snapshot.error == nil)
        #expect(fx.runner.invocations.contains { $0.contains("core.sshCommand") })
    }
}
