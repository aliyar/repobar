import Foundation
import Testing
@testable import GitEngine

@Suite("SchedulePlanner")
struct SchedulePlannerTests {
    let planner = SchedulePlanner()
    let interval = Duration.seconds(300)

    @Test func neverCheckedIsDue() {
        #expect(planner.isDue(state: nil, now: Date(), interval: interval, lowPower: false, reason: .interval))
    }

    @Test func respectsIntervalAndLowPower() {
        var state = RepoState()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000) // bucket 1_000_000 % 21 = 13 → +3 % jitter
        state.lastAttemptAt = now.addingTimeInterval(-200)
        #expect(!planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .interval))
        state.lastAttemptAt = now.addingTimeInterval(-340)
        #expect(planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .interval))
        #expect(!planner.isDue(state: state, now: now, interval: interval, lowPower: true, reason: .interval), "×3 in low power")
    }

    @Test func backoffBlocksAutomaticButNotManual() {
        var state = RepoState()
        state.lastAttemptAt = .distantPast
        state.backoffUntil = Date().addingTimeInterval(3600)
        #expect(!planner.isDue(state: state, now: Date(), interval: interval, lowPower: false, reason: .interval))
        #expect(!planner.isDue(state: state, now: Date(), interval: interval, lowPower: false, reason: .wake))
        #expect(planner.isDue(state: state, now: Date(), interval: interval, lowPower: false, reason: .manual))
        #expect(planner.isDue(state: state, now: Date(), interval: interval, lowPower: false, reason: .manualAll))
    }

    @Test func opportunisticReasonsUseSpacing() {
        var state = RepoState()
        let now = Date()
        state.lastAttemptAt = now.addingTimeInterval(-10)
        #expect(!planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .wake))
        #expect(!planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .panelOpened))
        state.lastAttemptAt = now.addingTimeInterval(-45)
        #expect(planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .networkUp))
        #expect(!planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .panelOpened))
        state.lastAttemptAt = now.addingTimeInterval(-61)
        #expect(planner.isDue(state: state, now: now, interval: interval, lowPower: false, reason: .panelOpened))
    }

    @Test func dueSortsStalestFirst() {
        let now = Date()
        let fresh = RepoRecord(path: "/a", gitCommonDir: "/a/.git")
        let stale = RepoRecord(path: "/b", gitCommonDir: "/b/.git")
        var freshState = RepoState(); freshState.lastSuccessAt = now.addingTimeInterval(-100)
        var staleState = RepoState(); staleState.lastSuccessAt = now.addingTimeInterval(-5000)
        let due = planner.due(now: now, records: [fresh, stale], states: [fresh.id: freshState, stale.id: staleState], interval: interval, lowPower: false, reason: .manualAll)
        #expect(due.map(\.id) == [stale.id, fresh.id])
    }
}

@Suite("BackoffPolicy")
struct BackoffPolicyTests {
    let policy = BackoffPolicy()
    let interval = Duration.seconds(300)

    @Test func authGrowsExponentiallyAndCaps() {
        #expect(policy.delay(afterFailures: 1, kind: .auth, interval: interval) == .seconds(300))
        #expect(policy.delay(afterFailures: 2, kind: .auth, interval: interval) == .seconds(600))
        #expect(policy.delay(afterFailures: 4, kind: .auth, interval: interval) == .seconds(2400))
        #expect(policy.delay(afterFailures: 20, kind: .auth, interval: interval) == .seconds(6 * 3600))
    }

    @Test func networkCapsAtFourTimes() {
        #expect(policy.delay(afterFailures: 1, kind: .network, interval: interval) == .seconds(300))
        #expect(policy.delay(afterFailures: 3, kind: .network, interval: interval) == .seconds(1200))
        #expect(policy.delay(afterFailures: 9, kind: .network, interval: interval) == .seconds(1200))
    }

    @Test func lockUserAndFatal() {
        #expect(policy.delay(afterFailures: 3, kind: .lock, interval: interval) == .zero)
        #expect(policy.delay(afterFailures: 3, kind: .user, interval: interval) == .zero)
        #expect(policy.delay(afterFailures: 1, kind: .fatal, interval: interval) == nil)
    }
}

@Suite("AcknowledgementRules")
struct AcknowledgementRulesTests {
    @Test func unseenCountsRightSide() {
        let outcome = AcknowledgementRules.apply(lastSeen: "a", tip: "b", leftRight: (0, 3), upstreamMode: true, behind: 3)
        #expect(outcome == .init(lastSeen: "a", unseen: 3, historyRewritten: false))
    }

    @Test func rewrittenWhenLastSeenIsNotAncestorOrUnknown() {
        #expect(AcknowledgementRules.apply(lastSeen: "a", tip: "b", leftRight: (1, 2), upstreamMode: true, behind: 2).historyRewritten)
        let missing = AcknowledgementRules.apply(lastSeen: "a", tip: "b", leftRight: nil, upstreamMode: false, behind: nil)
        #expect(missing == .init(lastSeen: "b", unseen: 0, historyRewritten: true))
    }

    @Test func pulledBranchAutoAcknowledges() {
        let outcome = AcknowledgementRules.apply(lastSeen: "a", tip: "b", leftRight: (0, 2), upstreamMode: true, behind: 0)
        #expect(outcome == .init(lastSeen: "b", unseen: 0, historyRewritten: false))
        let override = AcknowledgementRules.apply(lastSeen: "a", tip: "b", leftRight: (0, 2), upstreamMode: false, behind: 0)
        #expect(override.unseen == 2, "override mode ignores HEAD")
    }

    @Test func initialAndNotify() {
        #expect(AcknowledgementRules.initialLastSeen(upstreamMode: true, mergeBase: "m", tip: "t") == "m")
        #expect(AcknowledgementRules.initialLastSeen(upstreamMode: true, mergeBase: nil, tip: "t") == "t")
        #expect(AcknowledgementRules.initialLastSeen(upstreamMode: false, mergeBase: "m", tip: "t") == "t")
        #expect(AcknowledgementRules.shouldNotify(unseen: 1, tip: "t", lastNotified: nil, muted: false, hadSuccessfulCheckBefore: true))
        #expect(!AcknowledgementRules.shouldNotify(unseen: 1, tip: "t", lastNotified: "t", muted: false, hadSuccessfulCheckBefore: true))
        #expect(!AcknowledgementRules.shouldNotify(unseen: 1, tip: "t", lastNotified: nil, muted: true, hadSuccessfulCheckBefore: true))
        #expect(!AcknowledgementRules.shouldNotify(unseen: 1, tip: "t", lastNotified: nil, muted: false, hadSuccessfulCheckBefore: false))
        #expect(!AcknowledgementRules.shouldNotify(unseen: 0, tip: "t", lastNotified: nil, muted: false, hadSuccessfulCheckBefore: true))
    }
}

@Suite("Remote branch list")
struct RemoteBranchListTests {
    func ref(_ name: String, symref: String? = nil) -> RefRecord {
        RefRecord(refname: name, objectName: "abc", symref: symref, upstream: nil, upstreamRemoteName: nil, upstreamRemoteRef: nil)
    }

    @Test func stripsThePrefixAndDropsHead() {
        let refs = [
            ref("refs/remotes/origin/HEAD", symref: "refs/remotes/origin/main"),
            ref("refs/remotes/origin/main"),
            ref("refs/remotes/origin/release/2026"),
        ]
        #expect(WatchedRefResolver.branchNames(from: refs, remote: "origin") == ["main", "release/2026"])
    }

    @Test func commonBranchesComeFirstThenAlphabetical() {
        let names = ["zeta", "main", "alpha", "develop", "Beta"]
        let refs = names.map { ref("refs/remotes/origin/\($0)") }
        #expect(WatchedRefResolver.branchNames(from: refs, remote: "origin") == ["main", "develop", "alpha", "Beta", "zeta"])
    }

    @Test func ignoresOtherRemotesAndLocalBranches() {
        let refs = [
            ref("refs/heads/main"),
            ref("refs/remotes/upstream/main"),
            ref("refs/remotes/origin/feature"),
        ]
        #expect(WatchedRefResolver.branchNames(from: refs, remote: "origin") == ["feature"])
    }

    @Test func noBranchesIsEmptyNotAGuess() {
        #expect(WatchedRefResolver.branchNames(from: [], remote: "origin").isEmpty)
    }
}

@Suite("RepoPersistence")
struct RepoPersistenceTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("repobar-persist-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func roundTripsRecordsAndStates() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = RepoPersistence(directory: dir)
        var record = RepoRecord(path: "/tmp/x", gitCommonDir: "/tmp/x/.git", displayName: "X", colorID: "teal", watch: .remoteBranch("release"), addedAt: Date(timeIntervalSince1970: 1_700_000_000.25))
        // Every optional field is filled in: a field that is missing from CodingKeys
        // encodes to nothing and would fail the equality check below.
        record.notificationsMuted = true
        record.mutedUntil = Date(timeIntervalSince1970: 1_700_003_600)
        record.lastOpenedAppBundleID = "com.apple.TextEdit"
        record.bookmark = Data([1, 2, 3])
        record.remoteOverride = "upstream"
        record.webURLOverride = "https://example.com/x"
        record.includeUntracked = false
        record.sortOrder = 3
        var state = RepoState()
        state.lastSeenSHA["origin/main"] = "abc"
        state.lastSnapshot = RepoSnapshot(checkedAt: Date(timeIntervalSince1970: 1_700_000_000), unseenCount: 2, incoming: [
            IncomingCommit(sha: "abc", shortSHA: "abc", authorName: "A", authorEmail: "a@b", authorDate: Date(timeIntervalSince1970: 1), subject: "s"),
        ], error: .authFailed(.ssh))
        try await persistence.saveRecords([record])
        try await persistence.saveStates([record.id: state])

        let records = await persistence.loadRecords()
        let states = await persistence.loadStates()
        #expect(records == [record])
        #expect(states[record.id] == state)
    }

    @Test func corruptFileIsMovedAsideAndLoadIsEmpty() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persistence = RepoPersistence(directory: dir)
        try "{ not json".write(to: await persistence.recordsURL, atomically: true, encoding: .utf8)
        let records = await persistence.loadRecords()
        #expect(records.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("repos.json.corrupt-") })
        #expect(!files.contains("repos.json"))
    }

    @Test func mutingIsIndefiniteOrTimed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var record = RepoRecord(path: "/tmp/x", gitCommonDir: "/tmp/x/.git")
        #expect(!record.isMuted(at: now))

        record.mutedUntil = now.addingTimeInterval(3600)
        #expect(record.isMuted(at: now))
        #expect(!record.isMuted(at: now.addingTimeInterval(7200)), "a timed mute lifts itself")

        record.mutedUntil = nil
        record.notificationsMuted = true
        #expect(record.isMuted(at: now.addingTimeInterval(86_400 * 365)), "an indefinite mute never lifts")
    }

    @Test func missingKeysDecodeWithDefaults() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/tmp/y"}"#
        let record = try JSONDecoder().decode(RepoRecord.self, from: Data(json.utf8))
        #expect(record.watch == .upstreamOfCurrentBranch)
        #expect(record.gitCommonDir == "/tmp/y/.git")
        #expect(record.includeUntracked)
        let state = try JSONDecoder().decode(RepoState.self, from: Data("{}".utf8))
        #expect(state.consecutiveFailures == 0)
        // A snapshot written before remoteBranches existed must still load.
        let old = #"{"checkedAt":0,"unseenCount":0,"incoming":[],"workingTree":{"staged":0,"unstaged":0,"untracked":0,"conflicted":0},"isShallow":false,"historyRewritten":false,"networkMode":"fetched"}"#
        let snapshot = try JSONDecoder().decode(RepoSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.remoteBranches.isEmpty)
    }
}

@Suite("GitGate")
struct GitGateTests {
    @Test func serializesPerCommonDirAndLimitsGlobally() async throws {
        let gate = GitGate(maxConcurrent: 2)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                let dir = index < 3 ? "/shared/.git" : "/other-\(index)/.git"
                group.addTask {
                    try? await gate.withSlot(commonDir: dir) {
                        await tracker.enter(dir)
                        try? await Task.sleep(for: .milliseconds(40))
                        await tracker.exit(dir)
                    }
                }
            }
        }
        #expect(await tracker.maxGlobal <= 2)
        #expect(await tracker.maxPerDir["/shared/.git"] == 1)
    }

    @Test func cancelledWaiterDoesNotConsumeAPermit() async throws {
        let semaphore = AsyncSemaphore(1)
        try await semaphore.acquire()
        let waiter = Task { try await semaphore.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await semaphore.release()
        // The permit must be available again immediately.
        let acquired = Task { try await semaphore.acquire(); return true }
        #expect(try await acquired.value)
    }
}

actor ConcurrencyTracker {
    private var current = 0
    private var perDir: [String: Int] = [:]
    var maxGlobal = 0
    var maxPerDir: [String: Int] = [:]

    func enter(_ dir: String) {
        current += 1
        perDir[dir, default: 0] += 1
        maxGlobal = max(maxGlobal, current)
        maxPerDir[dir] = max(maxPerDir[dir] ?? 0, perDir[dir] ?? 0)
    }

    func exit(_ dir: String) {
        current -= 1
        perDir[dir, default: 0] -= 1
    }
}
