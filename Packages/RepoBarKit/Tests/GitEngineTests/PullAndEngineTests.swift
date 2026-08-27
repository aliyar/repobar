import Foundation
import Testing
@testable import GitEngine

@Suite("PullService (integration)", .timeLimit(.minutes(2)))
struct PullServiceTests {
    @Test func fastForwardsCleanBehindBranch() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)
        let tip = try await fx.commit(in: b, file: "new.txt", content: "n", message: "new")
        try await fx.push(in: b)
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.behind == 1)

        let result = try await PullService(git: fx.git).pull(record: record, snapshot: outcome.snapshot)
        #expect(result.toSHA == tip)
        #expect(result.commitCount == 1)
        #expect(try await fx.head(of: a) == tip)
        #expect(FileManager.default.fileExists(atPath: a.appendingPathComponent("new.txt").path))

        let after = await fx.check(record, state: outcome.state)
        #expect(after.snapshot.behind == 0)
        #expect(after.snapshot.unseenCount == 0)
    }

    @Test func refusals() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)

        let upToDate = await fx.check(record)
        #expect(throws: PullRefusal.nothingToPull) { try PullService.preflight(snapshot: upToDate.snapshot) }

        try await fx.commit(in: b, file: "r.txt", content: "r", message: "remote")
        try await fx.push(in: b)
        try "dirty\n".write(to: a.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let dirty = await fx.check(record)
        #expect(throws: PullRefusal.workingTreeDirty) { try PullService.preflight(snapshot: dirty.snapshot) }
        try await fx.sh(["checkout", "--", "README.md"], in: a)

        try await fx.commit(in: a, file: "l.txt", content: "l", message: "local")
        let diverged = await fx.check(record)
        #expect(throws: PullRefusal.diverged) { try PullService.preflight(snapshot: diverged.snapshot) }

        try await fx.sh(["checkout", "-q", "--detach"], in: a)
        let detached = await fx.check(record)
        #expect(throws: PullRefusal.detachedHead) { try PullService.preflight(snapshot: detached.snapshot) }

        let overrideRecord = try await fx.record(for: b, watch: .remoteBranch("main"))
        let override = await fx.check(overrideRecord)
        // Override of the same branch as upstream is allowed; a different branch is not.
        let other = try await fx.record(for: b, watch: .remoteBranch("other"))
        var fake = override.snapshot
        fake.watched = WatchedRef(remote: "origin", branch: "other", source: .override)
        fake.comparison = BranchComparison(ahead: 0, behind: 1)
        #expect(throws: PullRefusal.notWatchingUpstream) { try PullService.preflight(snapshot: fake) }
        _ = other
    }

    @Test func operationInProgressIsDetected() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let record = try await fx.record(for: a)
        try await fx.commit(in: b, file: "r.txt", content: "r", message: "remote")
        try await fx.push(in: b)
        let outcome = await fx.check(record)
        try Data().write(to: a.appendingPathComponent(".git/MERGE_HEAD"))
        await #expect(throws: PullRefusal.operationInProgress("merge")) {
            _ = try await PullService(git: fx.git).pull(record: record, snapshot: outcome.snapshot)
        }
    }
}

@Suite("RepoEngine (integration)", .timeLimit(.minutes(3)))
struct RepoEngineTests {
    func makeEngine(_ fx: GitFixture, settings: EngineSettings = EngineSettings()) -> (RepoEngine, URL) {
        let dir = fx.directory("persist-\(UUID().uuidString.prefix(6))")
        let engine = RepoEngine(persistence: RepoPersistence(directory: dir), settings: settings, runner: fx.runner, baseEnvironment: fx.environment)
        return (engine, dir)
    }

    /// The snapshot is minutes old by the time Pull is clicked; the merge would move whatever
    /// HEAD points at now. `git switch -c` keeps the SHA, so only the branch name gives it away.
    @Test func pullRefusesWhenTheCheckedOutBranchChanged() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        try await fx.commit(in: b, file: "n.txt", content: "n", message: "news")
        try await fx.push(in: b)
        let record = try await fx.record(for: a)
        let outcome = await fx.check(record)
        #expect(outcome.snapshot.behind == 1)

        let mainSHA = try await fx.head(of: a)
        _ = try await fx.sh(["switch", "-q", "-c", "topic"], in: a)
        let service = PullService(git: fx.git)
        await #expect(throws: PullRefusal.headMoved) {
            try await service.pull(record: record, snapshot: outcome.snapshot)
        }
        #expect(try await fx.head(of: a) == mainSHA, "topic must not have been fast-forwarded")
        _ = try await fx.sh(["switch", "-q", "main"], in: a)
        #expect(try await fx.head(of: a) == mainSHA, "main must not have moved either")
    }

    /// Suppressing the first notification has to set a baseline. Otherwise the next check sees
    /// the same tip with lastNotified still nil and announces commits that pre-date the add.
    @Test func addingABehindCloneNeverNotifiesAboutItsBacklog() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        for index in 1...3 {
            try await fx.commit(in: b, file: "\(index).txt", content: "\(index)", message: "old \(index)")
        }
        try await fx.push(in: b)
        let (engine, _) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()

        let record = try await engine.add(path: a)
        await engine.waitForIdle()
        #expect(await engine.state(for: record.id)?.lastSnapshot?.unseenCount == 3, "the backlog still lights up")

        await engine.checkNow(record.id)
        await engine.checkNow(record.id)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await collector.notifications.isEmpty, "commits that pre-date the add are never announced")
        await collector.stop()
    }

    /// apply() runs with the record the check captured. Muting mid-check must still count.
    @Test func mutingDuringACheckSuppressesItsNotification() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let (engine, _) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()

        try await fx.commit(in: b, file: "n.txt", content: "n", message: "news")
        try await fx.push(in: b)

        fx.runner.hold("fetch", for: .milliseconds(600))
        let check = Task { await engine.checkNow(record.id) }
        try await Task.sleep(for: .milliseconds(200))
        var muted = record
        muted.notificationsMuted = true
        await engine.update(muted)
        await check.value
        fx.runner.hold("", for: .zero)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(await engine.state(for: record.id)?.lastSnapshot?.unseenCount == 1, "the commit is still found")
        #expect(await collector.notifications.isEmpty, "a mute applied mid-check still silences its result")
        await collector.stop()
    }

    /// A check that ends without a tip carries a state copy that predates markSeen; writing it
    /// back would erase the acknowledgement and light the commits up again.
    @Test func acknowledgementSurvivesACheckThatEndsWithoutATip() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let (engine, _) = makeEngine(fx)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()   // add starts a check; checkNow would otherwise join it
        try await fx.commit(in: b, file: "n.txt", content: "n", message: "news")
        try await fx.push(in: b)
        await engine.checkNow(record.id)
        let tip = try #require(await engine.state(for: record.id)?.lastSnapshot?.watchedTipSHA)
        #expect(await engine.state(for: record.id)?.lastSnapshot?.unseenCount == 1)

        // The branch disappears from the remote: the next check stops at the probe with no tip.
        _ = try await fx.sh(["branch", "-D", "main"], in: remote)

        fx.runner.hold("ls-remote", for: .milliseconds(600))
        let check = Task { await engine.checkNow(record.id) }
        try await Task.sleep(for: .milliseconds(200))
        await engine.markSeen(record.id)
        await check.value
        fx.runner.hold("", for: .zero)

        let state = try #require(await engine.state(for: record.id))
        #expect(state.lastSnapshot?.watchedTipSHA == nil, "the check really did end without a tip")
        #expect(state.lastSeenSHA["origin/main"] == tip, "the acknowledgement survives")
        #expect(state.lastNotifiedSHA["origin/main"] == tip)
    }

    /// A trigger that arrives mid-check used to be dropped: the running check had already
    /// captured the old record, so changing the watched branch during a refresh left the
    /// repository showing the wrong branch until the next interval.
    @Test func aTriggerDuringACheckIsHonouredAfterwards() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let seed = try await fx.clone(remote, as: "seed")
        _ = try await fx.sh(["switch", "-q", "-c", "release"], in: seed)
        try await fx.commit(in: seed, file: "r.txt", content: "r", message: "on release")
        try await fx.push(in: seed, "release")

        let (engine, _) = makeEngine(fx)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()
        #expect(await engine.state(for: record.id)?.lastSnapshot?.watched?.branch == "main")

        fx.runner.hold("fetch", for: .milliseconds(600))
        let check = Task { await engine.checkNow(record.id) }
        try await Task.sleep(for: .milliseconds(200))
        var watched = record
        watched.watch = .remoteBranch("release")
        await engine.update(watched)      // dropped before: the check was already running
        await check.value
        fx.runner.hold("", for: .zero)
        await engine.waitForIdle()

        #expect(await engine.state(for: record.id)?.lastSnapshot?.watched?.branch == "release",
                "the queued trigger runs once the in-flight check finishes")
    }

    /// markSeen used to emit .snapshot, which the app reads as "the check finished": pressing
    /// Mark as seen during a refresh stopped the spinners and rewound "Updated …".
    @Test func markSeenIsAnAcknowledgementNotACheckResult() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let (engine, _) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()
        try await fx.commit(in: b, file: "n.txt", content: "n", message: "news")
        try await fx.push(in: b)
        await engine.checkNow(record.id)

        await engine.markSeen(record.id)
        #expect(await collector.waitForAcknowledgement(of: record.id),
                "the acknowledgement arrives as its own event, not as a check result")
        let seen = await collector.waitForSnapshot(for: record.id) { $0.unseenCount == 0 }
        #expect(seen != nil, "and the UI still receives the acknowledged snapshot")
        await collector.stop()
    }

    /// Settings › Advanced offers extra PATH entries, but they only reached the environment
    /// git ran in — a git living in one of them was never found, so "git not found" stayed
    /// on screen unless the user gave a full path override instead.
    @Test func extraPathsAreSearchedForGit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-extrapath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("git")
        try "#!/bin/sh\necho 'git version 2.99.0 (fake)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        var settings = EngineSettings()
        settings.extraPaths = [dir.path]
        let engineDir = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-extrapath-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: engineDir) }
        let engine = RepoEngine(persistence: RepoPersistence(directory: engineDir), settings: settings)
        await engine.relocateGit()

        #expect(await engine.installation?.url == fake, "the git in an extra PATH entry is found")
    }

    @Test func addCheckNotifyMarkSeenRemove() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let b = try await fx.clone(remote, as: "B")
        let (engine, dir) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()
        #expect(await engine.installation != nil)

        let record = try await engine.add(path: a)
        await engine.waitForIdle()
        let first = await engine.state(for: record.id)?.lastSnapshot
        #expect(first?.error == nil)
        #expect(first?.unseenCount == 0)
        await #expect(throws: EngineError.self) { try await engine.add(path: a) }

        try await fx.commit(in: b, file: "n.txt", content: "n", message: "news")
        try await fx.push(in: b)
        await engine.checkNow(record.id)
        let second = try #require(await engine.state(for: record.id)?.lastSnapshot)
        #expect(second.unseenCount == 1)
        #expect(await collector.waitForNotifications(count: 1).map(\.0.id) == [record.id], "exactly one notification after the second successful check")

        // Same tip again → no second notification.
        await engine.checkNow(record.id)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await collector.notifications.count == 1)

        await engine.markSeen(record.id)
        let seen = try #require(await engine.state(for: record.id)?.lastSnapshot)
        #expect(seen.unseenCount == 0)
        #expect(seen.incoming.first?.isNew == false)
        #expect(await engine.state(for: record.id)?.lastSeenSHA["origin/main"] == second.watchedTipSHA)
        let seenEvent = await collector.waitForSnapshot(for: record.id) { $0.unseenCount == 0 && $0.behind == 1 }
        #expect(seenEvent != nil, "UI receives the acknowledged snapshot")

        // Pull through the engine fast-forwards both pending commits and re-checks.
        try await fx.commit(in: b, file: "p.txt", content: "p", message: "pull me")
        try await fx.push(in: b)
        await engine.checkNow(record.id)
        let result = try await engine.pull(record.id)
        #expect(result.commitCount == 2)
        let pulled = await engine.state(for: record.id)?.lastSnapshot
        #expect(pulled?.behind == 0)
        #expect(try await fx.head(of: a) == result.toSHA)

        await engine.flush()
        let reloaded = RepoPersistence(directory: dir)
        #expect(await reloaded.loadRecords().map(\.id) == [record.id])
        #expect(await reloaded.loadStates()[record.id]?.lastSnapshot?.behind == 0)

        await engine.remove(record.id)
        #expect(await engine.currentRecords().isEmpty)
        await engine.flush()
        #expect(await reloaded.loadRecords().isEmpty)
        await collector.stop()
    }

    @Test func bareAndNonRepoAreRejected() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let (engine, _) = makeEngine(fx)
        await engine.start()
        await #expect(throws: EngineError.self) { try await engine.add(path: remote) }
        let plain = fx.directory("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        do {
            _ = try await engine.add(path: plain)
            Issue.record("expected failure")
        } catch let error as EngineError {
            if case .notARepository = error {} else { Issue.record("unexpected \(error)") }
        }
    }

    @Test func worktreesShareCommonDirAndBothGetSnapshots() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let wt = fx.directory("A-wt")
        try await fx.sh(["worktree", "add", "-q", "-b", "wt-branch", wt.path], in: a)
        let (engine, _) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()
        let r1 = try await engine.add(path: a)
        let r2 = try await engine.add(path: wt)
        #expect(URL(fileURLWithPath: r1.gitCommonDir).standardizedFileURL.path == URL(fileURLWithPath: r2.gitCommonDir).standardizedFileURL.path)
        await engine.waitForIdle()
        #expect(await collector.lastSnapshot(for: r1.id)?.error == nil)
        #expect(await collector.lastSnapshot(for: r2.id)?.error == nil)
        await collector.stop()
    }

    @Test func pausedAndOfflineModes() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let (engine, _) = makeEngine(fx)
        let collector = EventCollector(engine.events)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()

        await engine.setOnline(false)
        await engine.checkNow(record.id)
        #expect(await collector.lastSnapshot(for: record.id)?.networkMode == .offlineLocalOnly)

        await engine.setOnline(true)
        await engine.setPaused(true)
        await engine.trigger(.interval)
        await engine.waitForIdle()
        // Paused: interval triggers do nothing; manual still works but skips the network.
        await engine.checkNow(record.id)
        #expect(await collector.lastSnapshot(for: record.id)?.networkMode == .skippedPaused)
        await engine.setPaused(false)
        await collector.stop()
    }

    @Test func failuresApplyBackoffAndManualResets() async throws {
        let fx = try await GitFixture()
        let remote = try await fx.makeRemote()
        let a = try await fx.clone(remote, as: "A")
        let (engine, _) = makeEngine(fx)
        await engine.start()
        let record = try await engine.add(path: a)
        await engine.waitForIdle()
        // Point origin at a dead URL → network failure → backoff.
        try await fx.sh(["remote", "set-url", "origin", "https://127.0.0.1:1/x.git"], in: a)
        var updated = record
        updated.includeUntracked = false // forces a re-check via update()
        await engine.update(updated)
        await engine.waitForIdle()
        let state = try #require(await engine.state(for: record.id))
        #expect(state.consecutiveFailures == 1)
        #expect(state.lastSnapshot?.error == .networkUnreachable)
        #expect((state.backoffUntil ?? .distantPast) > Date())

        try await fx.sh(["remote", "set-url", "origin", remote.path], in: a)
        await engine.checkNow(record.id)
        let recovered = try #require(await engine.state(for: record.id))
        #expect(recovered.consecutiveFailures == 0)
        #expect(recovered.backoffUntil == nil)
        #expect(recovered.lastSnapshot?.error == nil)
    }
}

/// Collects engine events in the background.
actor EventCollector {
    private var snapshots: [RepoID: RepoSnapshot] = [:]
    private(set) var notifications: [(RepoRecord, RepoSnapshot)] = []
    private(set) var acknowledged: [RepoID] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EngineEvent>) {
        Task { await self.start(stream) }
    }

    private func start(_ stream: AsyncStream<EngineEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .snapshot(let id, let snapshot): snapshots[id] = snapshot
        case .acknowledged(let id, let snapshot):
            snapshots[id] = snapshot
            acknowledged.append(id)
        case .notify(let record, let snapshot): notifications.append((record, snapshot))
        default: break
        }
    }

    func lastSnapshot(for id: RepoID) async -> RepoSnapshot? {
        // Events are delivered asynchronously; give the stream a moment to drain.
        for _ in 0..<20 {
            if let snapshot = snapshots[id] { return snapshot }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return snapshots[id]
    }

    func waitForAcknowledgement(of id: RepoID) async -> Bool {
        for _ in 0..<40 {
            if acknowledged.contains(id) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    func waitForSnapshot(for id: RepoID, where predicate: (RepoSnapshot) -> Bool) async -> RepoSnapshot? {
        for _ in 0..<40 {
            if let snapshot = snapshots[id], predicate(snapshot) { return snapshot }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    func waitForNotifications(count: Int) async -> [(RepoRecord, RepoSnapshot)] {
        for _ in 0..<40 {
            if notifications.count >= count { return notifications }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return notifications
    }

    func stop() { task?.cancel() }
}
