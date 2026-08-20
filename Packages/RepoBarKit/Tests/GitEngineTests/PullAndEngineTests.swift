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
