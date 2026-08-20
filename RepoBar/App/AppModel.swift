import AppKit
import Observation
import OSLog
import GitEngine

/// Main-actor view model: turns `RepoEngine` events into UI state and exposes user actions.
@Observable
final class AppModel {
    let engine: RepoEngine
    let settings: AppSettings

    private(set) var records: [RepoRecord] = []
    private(set) var snapshots: [RepoID: RepoSnapshot] = [:]
    private(set) var checking: Set<RepoID> = []
    private(set) var gitInstallation: GitInstallation?
    private(set) var gitDiscoveryFinished = false
    private(set) var isPaused = false
    private(set) var isOnline = true
    private(set) var lastRefresh: Date?
    private(set) var pausedUntil: Date?
    var toast: Toast?
    var pendingDiscovery: DiscoveryProposal?

    /// Wired by AppDependencies: close the popover (e.g. after opening another app).
    @ObservationIgnored var closePanel: (() -> Void)?
    /// Wired by AppDependencies: post a user notification.
    @ObservationIgnored var onNotify: ((RepoRecord, RepoSnapshot) -> Void)?
    /// Wired by AppDependencies: ask for notification permission (fires once, when repositories first appear).
    @ObservationIgnored var onRepositoriesAvailable: (() -> Void)?
    @ObservationIgnored private var announcedRepositories = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?

    init(engine: RepoEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        settings.onEngineSettingsChange = { [weak self] in
            guard let self else { return }
            let engineSettings = settings.engineSettings
            Task { await self.engine.applySettings(engineSettings) }
        }
    }

    // MARK: - Derived state

    var items: [RepoItem] {
        records.map { record in
            RepoItem(record: record, snapshot: snapshots[record.id], isChecking: checking.contains(record.id), color: color(for: record))
        }
    }

    func sortedItems(matching query: String = "") -> [RepoItem] {
        RepoSorting.sort(RepoSorting.filter(items, query: query))
    }

    func item(for id: RepoID) -> RepoItem? {
        items.first { $0.id == id }
    }

    var isRefreshing: Bool { !checking.isEmpty }
    var unseenRepoCount: Int { items.filter { $0.unseen > 0 }.count }
    var errorCount: Int { items.filter { $0.error != nil }.count }
    var gitMissing: Bool { gitDiscoveryFinished && gitInstallation == nil }

    var menuBar: MenuBarState {
        MenuBarState(
            repos: items.map(\.dot),
            isChecking: isRefreshing,
            isPaused: isPaused,
            isOffline: !isOnline,
            style: settings.menuBarStyle,
            showIdleDots: settings.showIdleDots,
            idleDotStyle: settings.idleDotStyle,
            badgeMode: settings.badgeMode
        )
    }

    /// Header status line.
    var statusLine: String {
        if gitMissing { return "git not found — open Settings" }
        if isPaused {
            if let pausedUntil { return "Paused until \(pausedUntil.formatted(date: .omitted, time: .shortened))" }
            return "Paused"
        }
        if !isOnline { return "Offline — will retry" }
        if isRefreshing { return "Checking…" }
        if errorCount > 0 { return "Check failed for \(errorCount) \(errorCount == 1 ? "repository" : "repositories")" }
        if records.isEmpty { return "No repositories" }
        let changed = unseenRepoCount
        if changed > 0 { return "\(changed) of \(records.count) \(records.count == 1 ? "repository has" : "repositories have") new commits" }
        return "All up to date"
    }

    func color(for record: RepoRecord) -> RepoColor {
        if let id = record.colorID, let color = RepoColor(rawValue: id) { return color }
        return .blue
    }

    // MARK: - Lifecycle

    func start() {
        guard eventTask == nil else { return }
        let events = engine.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        let engine = engine
        let engineSettings = settings.engineSettings
        Task {
            await engine.applySettings(engineSettings)
            await engine.start()
        }
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .records(let records):
            self.records = records
            assignMissingColors()
            if !records.isEmpty, !announcedRepositories {
                announcedRepositories = true
                onRepositoriesAvailable?()
            }
        case .checkStarted(let id):
            checking.insert(id)
        case .snapshot(let id, let snapshot):
            snapshots[id] = snapshot
            checking.remove(id)
            lastRefresh = snapshot.checkedAt
        case .removed(let id):
            snapshots[id] = nil
            checking.remove(id)
        case .gitInstallation(let installation):
            gitInstallation = installation
            gitDiscoveryFinished = true
        case .notify(let record, let snapshot):
            guard settings.notificationsEnabled else { return }
            onNotify?(record, snapshot)
        case .paused(let paused):
            isPaused = paused
        case .online(let online):
            isOnline = online
        }
    }

    /// Gives each repository a stable color the first time we see it.
    private func assignMissingColors() {
        var used = records.compactMap { $0.colorID.flatMap(RepoColor.init(rawValue:)) }
        for record in records where record.colorID == nil {
            var updated = record
            let color = RepoColor.next(excluding: used)
            used.append(color)
            updated.colorID = color.rawValue
            if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = updated }
            Task { await engine.update(updated) }
        }
    }

    // MARK: - Actions

    func refreshAll() {
        Task { await engine.trigger(.manualAll) }
    }

    func refresh(_ id: RepoID) {
        Task { await engine.checkNow(id) }
    }

    func panelDidOpen() {
        toast = nil
        guard settings.refreshOnPanelOpen else { return }
        Task { await engine.trigger(.panelOpened) }
    }

    func markSeen(_ id: RepoID) {
        Task { await engine.markSeen(id) }
    }

    func markAllSeen() {
        Task { await engine.markAllSeen() }
    }

    func remove(_ id: RepoID) {
        Task { await engine.remove(id) }
    }

    func setMuted(_ id: RepoID, _ muted: Bool) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.notificationsMuted = muted
        Task { await engine.update(record) }
    }

    func setColor(_ id: RepoID, _ color: RepoColor) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.colorID = color.rawValue
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
        Task { await engine.update(record) }
    }

    func setWatch(_ id: RepoID, _ watch: WatchMode) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.watch = watch
        Task { await engine.update(record) }
    }

    func setDisplayName(_ id: RepoID, _ name: String?) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        record.displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        Task { await engine.update(record) }
    }

    func pull(_ id: RepoID) {
        Task {
            do {
                let result = try await engine.pull(id)
                showToast("Pulled \(result.commitCount) \(result.commitCount == 1 ? "commit" : "commits")", kind: .success)
            } catch let error as EngineError {
                showToast(error.message, kind: .failure)
            } catch {
                showToast(error.localizedDescription, kind: .failure)
            }
        }
    }

    func togglePause() {
        if isPaused { resume() } else { pause(for: nil) }
    }

    func pause(for duration: Duration?) {
        pauseTask?.cancel()
        pausedUntil = duration.map { Date().addingTimeInterval($0.seconds) }
        Task { await engine.setPaused(true) }
        if let duration {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.resume()
            }
        }
    }

    func resume() {
        pauseTask?.cancel()
        pausedUntil = nil
        Task { await engine.setPaused(false) }
    }

    func setOnline(_ online: Bool) {
        Task { await engine.setOnline(online) }
    }

    func setLowPower(_ lowPower: Bool) {
        Task { await engine.setLowPower(lowPower) }
    }

    func trigger(_ reason: CheckReason) {
        Task { await engine.trigger(reason) }
    }

    func relocateGit() {
        Task { await engine.relocateGit() }
    }

    // MARK: - Adding repositories

    func presentOpenPanel() {
        AppActivation.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose git repositories (or a folder that contains them)"
        panel.prompt = "Add"
        let developer = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Developer")
        panel.directoryURL = FileManager.default.fileExists(atPath: developer.path) ? developer : URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await addRepositories(urls) }
    }

    /// Adds repositories; a non-repo folder that contains repositories becomes a discovery proposal.
    func addRepositories(_ urls: [URL]) async {
        var added = 0
        var lastError: String?
        for url in urls {
            do {
                _ = try await engine.add(path: url)
                added += 1
            } catch let error as EngineError {
                if case .notARepository = error {
                    let found = await engine.discoverRepositories(in: url)
                    if !found.isEmpty {
                        pendingDiscovery = DiscoveryProposal(folder: url, repositories: found)
                        continue
                    }
                }
                lastError = error.message
            } catch {
                lastError = error.localizedDescription
            }
        }
        if added > 0 {
            showToast(added == 1 ? "Added \(urls.count == 1 ? urls[0].lastPathComponent : "1 repository")" : "Added \(added) repositories", kind: .success)
        } else if let lastError {
            showToast(lastError, kind: .failure)
        }
    }

    func confirmDiscovery() {
        guard let proposal = pendingDiscovery else { return }
        pendingDiscovery = nil
        Task { await addRepositories(proposal.repositories) }
    }

    func dismissDiscovery() {
        pendingDiscovery = nil
    }

    // MARK: - Opening things

    func defaultOpenApp() -> ExternalApp {
        ExternalAppCatalog.app(withID: settings.defaultOpenAppBundleID).flatMap { app in
            ExternalAppCatalog.installed().contains(app) ? app : nil
        } ?? .finder
    }

    func open(_ id: RepoID, in app: ExternalApp? = nil) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        OpenInService.open(record.url, in: app ?? defaultOpenApp())
    }

    func copyPath(_ id: RepoID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.path, forType: .string)
        showToast("Copied path", kind: .info)
    }

    func commitURL(_ id: RepoID, sha: String) -> URL? {
        snapshots[id]?.web?.commitURL(sha)
    }

    func openCommit(_ id: RepoID, sha: String) {
        guard let url = commitURL(id, sha: sha) else {
            showToast("No web URL for this remote", kind: .info)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openRepositoryPage(_ id: RepoID) {
        guard let url = snapshots[id]?.web?.repoURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Toast

    func showToast(_ message: String, kind: Toast.Kind = .info) {
        toast = Toast(message: message, kind: kind)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: - Preview

    static func preview() -> AppModel {
        let model = AppModel(engine: RepoEngine(persistence: RepoPersistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent("repobar-preview"))), settings: AppSettings(defaults: UserDefaults(suiteName: "preview")!))
        return model
    }
}
