import Foundation
import os

public struct EngineSettings: Sendable, Hashable {
    public var checkInterval: Duration = .seconds(300)
    public var maxConcurrentChecks = 4
    public var fetchTimeout: Duration = .seconds(90)
    public var probeBeforeFetch = true
    public var pruneOnFetch = false
    public var gitPathOverride: String?
    public var extraPaths: [String] = []

    public init() {}
}

public enum EngineEvent: Sendable {
    case records([RepoRecord])
    case checkStarted(RepoID)
    case snapshot(RepoID, RepoSnapshot)
    case removed(RepoID)
    case gitInstallation(GitInstallation?)
    /// The engine decided a user notification is warranted for this check.
    case notify(RepoRecord, RepoSnapshot)
    case paused(Bool)
    case online(Bool)
}

public enum EngineError: Error, Sendable {
    case gitNotFound
    case notARepository(String)
    case bareRepository
    case alreadyAdded(RepoRecord)
    case unknownRepository
    case pullRefused(PullRefusal)
    case git(RepoError)

    public var message: String {
        switch self {
        case .gitNotFound: "git was not found. Set its path in Settings › Advanced."
        case .notARepository(let detail): detail.isEmpty ? "Not a git repository." : detail
        case .bareRepository: "Bare repositories are not supported — add a working copy."
        case .alreadyAdded(let record): "\(record.name) is already in the list."
        case .unknownRepository: "Repository not found."
        case .pullRefused(let refusal): refusal.message
        case .git(let error): error.title
        }
    }
}

/// Coordinates checks for all repositories: scheduling, concurrency, backoff, acknowledgement,
/// persistence and event emission (plan §5.6). The app talks only to this actor.
public actor RepoEngine {
    public nonisolated let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let persistence: RepoPersistence
    private let runner: any ProcessRunning
    private let baseEnvironment: [String: String]
    private let planner = SchedulePlanner()
    private let backoff = BackoffPolicy()
    private let logger = Logger(subsystem: "com.aliyar.RepoBar", category: "engine")

    private var settings: EngineSettings
    private var records: [RepoRecord] = []
    private var states: [RepoID: RepoState] = [:]
    private var inFlight: [RepoID: Task<Void, Never>] = [:]
    private var pendingSeen: Set<RepoID> = []
    private var ticker: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var gate: GitGate
    private var git: GitClient?
    private(set) public var installation: GitInstallation?
    private(set) public var isPaused = false
    private(set) public var isOnline = true
    private(set) public var isLowPower = false
    private var started = false

    public init(
        persistence: RepoPersistence = RepoPersistence(),
        settings: EngineSettings = EngineSettings(),
        runner: any ProcessRunning = FoundationProcessRunner(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.persistence = persistence
        self.settings = settings
        self.runner = runner
        self.baseEnvironment = baseEnvironment
        self.gate = GitGate(maxConcurrent: settings.maxConcurrentChecks)
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    /// Loads persisted data (emitting cached snapshots immediately), locates git, schedules the
    /// first check shortly after launch and starts the ticker.
    public func start() async {
        guard !started else { return }
        started = true
        records = await persistence.loadRecords().sorted { $0.sortOrder < $1.sortOrder }
        states = await persistence.loadStates()
        continuation.yield(.records(records))
        for record in records {
            if let snapshot = states[record.id]?.lastSnapshot {
                continuation.yield(.snapshot(record.id, snapshot))
            }
        }
        await relocateGit()
        ticker = Task { [weak self] in
            await self?.runTicker()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.trigger(.launch)
        }
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    private func runTicker() async {
        while !Task.isCancelled {
            let tick = min(Duration.seconds(30), .seconds(max(15, settings.checkInterval.seconds / 4)))
            try? await Task.sleep(for: tick, tolerance: tick / 4)
            if Task.isCancelled { return }
            runDue(reason: .interval)
        }
    }

    // MARK: - Git discovery

    public func relocateGit() async {
        let locator = GitLocator(runner: runner)
        let override = settings.gitPathOverride.map { URL(fileURLWithPath: $0) }
        installation = await locator.locate(override: override)
        if let installation {
            git = makeClient(installation)
            logger.notice("using git \(installation.version, privacy: .public) at \(installation.url.path, privacy: .public)")
        } else {
            git = nil
            logger.error("no usable git found")
        }
        continuation.yield(.gitInstallation(installation))
    }

    private func makeClient(_ installation: GitInstallation) -> GitClient {
        let local = GitEnvironment.make(base: baseEnvironment, gitExecutable: installation.url, extraPaths: settings.extraPaths, sshBatchMode: false)
        let network = GitEnvironment.make(base: baseEnvironment, gitExecutable: installation.url, extraPaths: settings.extraPaths, sshBatchMode: true)
        return GitClient(installation: installation, runner: runner, environment: local, networkEnvironment: network)
    }

    // MARK: - Queries

    public func currentRecords() -> [RepoRecord] { records }
    public func state(for id: RepoID) -> RepoState? { states[id] }
    public func currentSettings() -> EngineSettings { settings }

    // MARK: - Triggers

    public func trigger(_ reason: CheckReason) {
        runDue(reason: reason)
    }

    private func runDue(reason: CheckReason) {
        if isPaused && !reason.isManual { return }
        let due = planner.due(now: Date(), records: records, states: states, interval: settings.checkInterval, lowPower: isLowPower, reason: reason)
        for record in due { startCheck(record.id, reason: reason) }
    }

    /// Checks one repository now, bypassing backoff. Joins an in-flight check if there is one.
    public func checkNow(_ id: RepoID) async {
        if let task = inFlight[id] {
            await task.value
            return
        }
        startCheck(id, reason: .manual)
        await inFlight[id]?.value
    }

    /// Waits for all in-flight checks (tests and "refresh all").
    public func waitForIdle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    private func startCheck(_ id: RepoID, reason: CheckReason) {
        guard inFlight[id] == nil, let record = records.first(where: { $0.id == id }) else { return }
        if reason.isManual {
            states[id, default: RepoState()].consecutiveFailures = 0
            states[id]?.backoffUntil = nil
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCheck(record, reason: reason)
            await self.clearInFlight(id)
        }
        inFlight[id] = task
    }

    private func clearInFlight(_ id: RepoID) {
        inFlight[id] = nil
    }

    private func performCheck(_ record: RepoRecord, reason: CheckReason) async {
        let state = states[record.id] ?? RepoState()
        continuation.yield(.checkStarted(record.id))
        guard let git else {
            var snapshot = state.lastSnapshot ?? RepoSnapshot(checkedAt: Date())
            snapshot.checkedAt = Date()
            snapshot.error = .gitNotFound
            apply(CheckOutcome(snapshot: snapshot, state: state), for: record)
            return
        }
        let backoffActive = (state.backoffUntil ?? .distantPast) > Date() && !reason.isManual
        let allowNetwork = isOnline && !isPaused && !backoffActive
        let skipped: NetworkMode = !isOnline ? .offlineLocalOnly : isPaused ? .skippedPaused : .skippedBackoff
        let options = CheckOptions(
            now: Date(),
            allowNetwork: allowNetwork,
            skippedReason: skipped,
            probeBeforeFetch: settings.probeBeforeFetch,
            pruneOnFetch: settings.pruneOnFetch,
            fetchTimeout: settings.fetchTimeout
        )
        let checker = RepoChecker(git: git)
        let commonDir = record.gitCommonDir
        do {
            let outcome = try await gate.withSlot(commonDir: commonDir) {
                await checker.check(record, state: state, options: options)
            }
            if Task.isCancelled { return }
            apply(outcome, for: record)
        } catch {
            // Cancelled while waiting for a slot.
        }
    }

    private func apply(_ outcome: CheckOutcome, for record: RepoRecord) {
        let now = Date()
        let previous = states[record.id] ?? RepoState()
        var state = outcome.state
        var snapshot = outcome.snapshot
        state.lastAttemptAt = now

        if let error = snapshot.error {
            let kind = error.failureKind
            switch kind {
            case .lock, .user:
                state.lastFailureKind = kind
            default:
                state.consecutiveFailures += 1
                state.lastFailureKind = kind
                if let delay = backoff.delay(afterFailures: state.consecutiveFailures, kind: kind, interval: settings.checkInterval) {
                    state.backoffUntil = delay == .zero ? nil : now.addingTimeInterval(delay.seconds)
                } else {
                    state.backoffUntil = .distantFuture
                }
            }
        } else {
            state.consecutiveFailures = 0
            state.lastFailureKind = nil
            state.backoffUntil = nil
            state.lastSuccessAt = now
        }

        // "Mark as seen" requested while this check was running wins over the check's result.
        if pendingSeen.remove(record.id) != nil, let watched = snapshot.watched, let tip = snapshot.watchedTipSHA {
            state.lastSeenSHA[watched.key] = tip
            snapshot.unseenCount = 0
            for index in snapshot.incoming.indices { snapshot.incoming[index].isNew = false }
        }

        if snapshot.error == nil, let watched = snapshot.watched, let tip = snapshot.watchedTipSHA {
            let notify = AcknowledgementRules.shouldNotify(
                unseen: snapshot.unseenCount,
                tip: tip,
                lastNotified: state.lastNotifiedSHA[watched.key],
                muted: record.notificationsMuted,
                hadSuccessfulCheckBefore: previous.lastSuccessAt != nil
            )
            if notify {
                state.lastNotifiedSHA[watched.key] = tip
                continuation.yield(.notify(record, snapshot))
            } else if snapshot.unseenCount == 0 {
                state.lastNotifiedSHA[watched.key] = tip
            }
        }

        state.lastSnapshot = snapshot
        states[record.id] = state
        continuation.yield(.snapshot(record.id, snapshot))
        scheduleSave()
    }

    // MARK: - Repository management

    @discardableResult
    public func add(path: URL) async throws -> RepoRecord {
        guard let git else { throw EngineError.gitNotFound }
        let validation: RepoValidation
        do {
            validation = try await RepoChecker(git: git).validate(path: path)
        } catch let error as GitError {
            let repoError = error.repoError
            if case .notARepository = repoError { throw EngineError.notARepository("\(path.lastPathComponent) is not a git repository.") }
            throw EngineError.git(repoError)
        }
        if validation.isBare { throw EngineError.bareRepository }
        let toplevel = URL(fileURLWithPath: validation.toplevel).standardizedFileURL.path
        if let existing = records.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == toplevel }) {
            throw EngineError.alreadyAdded(existing)
        }
        let record = RepoRecord(path: toplevel, gitCommonDir: validation.gitCommonDir, sortOrder: (records.map(\.sortOrder).max() ?? -1) + 1)
        records.append(record)
        continuation.yield(.records(records))
        persistRecords()
        startCheck(record.id, reason: .manual)
        return record
    }

    public func discoverRepositories(in folder: URL) -> [URL] {
        RepoChecker.discoverRepositories(in: folder)
    }

    public func remove(_ id: RepoID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        records.removeAll { $0.id == id }
        states[id] = nil
        continuation.yield(.removed(id))
        continuation.yield(.records(records))
        persistRecords()
        scheduleSave()
    }

    public func update(_ record: RepoRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        records[index] = record
        continuation.yield(.records(records))
        persistRecords()
        if previous.watch != record.watch || previous.remoteOverride != record.remoteOverride || previous.includeUntracked != record.includeUntracked || previous.webURLOverride != record.webURLOverride {
            startCheck(record.id, reason: .manual)
        }
    }

    public func reorder(_ ids: [RepoID]) {
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        for index in records.indices {
            records[index].sortOrder = order[records[index].id] ?? records[index].sortOrder
        }
        records.sort { $0.sortOrder < $1.sortOrder }
        continuation.yield(.records(records))
        persistRecords()
    }

    // MARK: - Acknowledgement

    public func markSeen(_ id: RepoID) {
        guard var state = states[id] else { return }
        if inFlight[id] != nil { pendingSeen.insert(id) }
        guard var snapshot = state.lastSnapshot, let watched = snapshot.watched, let tip = snapshot.watchedTipSHA else { return }
        state.lastSeenSHA[watched.key] = tip
        state.lastNotifiedSHA[watched.key] = tip
        snapshot.unseenCount = 0
        for index in snapshot.incoming.indices { snapshot.incoming[index].isNew = false }
        state.lastSnapshot = snapshot
        states[id] = state
        continuation.yield(.snapshot(id, snapshot))
        scheduleSave()
    }

    public func markAllSeen() {
        for record in records { markSeen(record.id) }
    }

    // MARK: - Pull

    public func pull(_ id: RepoID) async throws -> PullResult {
        guard let git else { throw EngineError.gitNotFound }
        guard let record = records.first(where: { $0.id == id }) else { throw EngineError.unknownRepository }
        if let task = inFlight[id] { await task.value }
        let snapshot = states[id]?.lastSnapshot
        do {
            try PullService.preflight(snapshot: snapshot)
        } catch {
            throw EngineError.pullRefused(error)
        }
        let service = PullService(git: git)
        let commonDir = record.gitCommonDir
        let result: PullResult
        do {
            result = try await gate.withSlot(commonDir: commonDir) {
                try await service.pull(record: record, snapshot: snapshot)
            }
        } catch let refusal as PullRefusal {
            throw EngineError.pullRefused(refusal)
        } catch let error as GitError {
            throw EngineError.git(error.repoError)
        }
        markSeen(id)
        await checkNow(id)
        return result
    }

    // MARK: - Environment toggles

    public func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        continuation.yield(.paused(paused))
        if !paused { runDue(reason: .settingsChanged) }
    }

    public func setOnline(_ online: Bool) {
        guard isOnline != online else { return }
        isOnline = online
        continuation.yield(.online(online))
        if online { runDue(reason: .networkUp) }
    }

    public func setLowPower(_ lowPower: Bool) {
        isLowPower = lowPower
    }

    public func applySettings(_ newSettings: EngineSettings) async {
        let old = settings
        settings = newSettings
        if old.maxConcurrentChecks != newSettings.maxConcurrentChecks {
            gate = GitGate(maxConcurrent: newSettings.maxConcurrentChecks)
        }
        if old.gitPathOverride != newSettings.gitPathOverride || old.extraPaths != newSettings.extraPaths {
            await relocateGit()
            runDue(reason: .settingsChanged)
        } else if let installation, old != newSettings {
            git = makeClient(installation)
        }
    }

    // MARK: - Persistence

    private func persistRecords() {
        let snapshot = records
        Task { [persistence, logger] in
            do { try await persistence.saveRecords(snapshot) } catch { logger.error("saving repos failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.persistStates()
        }
    }

    private func persistStates() async {
        do { try await persistence.saveStates(states) } catch { logger.error("saving state failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Flushes pending writes (used on quit and in tests).
    public func flush() async {
        saveTask?.cancel()
        await persistStates()
        try? await persistence.saveRecords(records)
    }
}
