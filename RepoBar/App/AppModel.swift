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
    /// Everything a repository can be opened with: the built-in catalog narrowed to
    /// what is installed, plus the apps the user added by hand. Stored rather than
    /// computed so SwiftUI reliably re-renders when it changes.
    private(set) var openApps: [ExternalApp] = []
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
    @ObservationIgnored var onNotifyUnpushed: ((RepoRecord, RepoSnapshot) -> Void)?
    /// Wired by AppDependencies: ask for notification permission (fires once, when repositories first appear).
    @ObservationIgnored var onRepositoriesAvailable: (() -> Void)?
    @ObservationIgnored private var announcedRepositories = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?

    init(engine: RepoEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
        refreshOpenApps()
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
            repos: sortedItems().map(\.dot),
            isChecking: isRefreshing,
            isPaused: isPaused,
            isOffline: !isOnline,
            style: settings.menuBarStyle,
            showIdleDots: settings.showIdleDots,
            idleDotStyle: settings.idleDotStyle,
            maxDots: settings.maxMenuBarDots,
            badgeMode: settings.badgeMode
        )
    }

    /// Header status line.
    var statusLine: String {
        if gitMissing { return "git not found — open Settings" }
        if isPaused {
            if let pausedUntil { return "Paused until \(Self.untilLabel(pausedUntil))" }
            return "Paused"
        }
        if !isOnline { return "Offline — will retry" }
        if isRefreshing { return "Checking…" }
        if records.isEmpty { return "No repositories" }
        let changed = unseenRepoCount
        let failed = errorCount > 0 ? " · \(errorCount) failed" : ""
        if changed > 0 { return "\(changed) of \(records.count) \(records.count == 1 ? "repository has" : "repositories have") new commits" + failed }
        if errorCount > 0 { return "Check failed for \(errorCount) \(errorCount == 1 ? "repository" : "repositories")" }
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

    /// Feeds one engine event through the same path the live stream uses. Tests only.
    func handleForTesting(_ event: EngineEvent) { handle(event) }

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
            // A snapshot can be older than one already shown (an acknowledgement carries the
            // previous check's time), and "Updated 2 min ago" must never run backwards.
            lastRefresh = max(lastRefresh ?? .distantPast, snapshot.checkedAt)
        case .acknowledged(let id, let snapshot):
            snapshots[id] = snapshot
        case .removed(let id):
            snapshots[id] = nil
            checking.remove(id)
        case .gitInstallation(let installation):
            gitInstallation = installation
            gitDiscoveryFinished = true
        case .notify(let record, let snapshot):
            guard settings.notificationsEnabled else { return }
            onNotify?(record, snapshot)
        case .notifyUnpushed(let record, let snapshot):
            guard settings.notificationsEnabled, settings.unpushedReminderEnabled else { return }
            onNotifyUnpushed?(record, snapshot)
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
        refreshOpenApps()
        scanWatchedFolders()
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

    // MARK: - Notification snooze (all repositories)

    var isSnoozed: Bool {
        guard let until = settings.notificationsSnoozedUntil else { return false }
        return Date() < until
    }

    var snoozedUntilLabel: String? {
        guard isSnoozed, let until = settings.notificationsSnoozedUntil else { return nil }
        return Self.untilLabel(until)
    }

    /// "2:30 PM" today, "tomorrow 9:00 AM" past midnight — a bare time is ambiguous
    /// for anything that runs overnight, which is what people forget about.
    nonisolated static func untilLabel(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func snoozeNotifications(for duration: Duration) {
        settings.notificationsSnoozedUntil = Date().addingTimeInterval(Double(duration.components.seconds))
        showToast("Notifications silenced until \(snoozedUntilLabel ?? "later")", kind: .info)
    }

    func resumeNotifications() {
        settings.notificationsSnoozedUntil = nil
        showToast("Notifications back on", kind: .info)
    }

    /// Indefinite mute. Clearing it also lifts any temporary silence.
    func setMuted(_ id: RepoID, _ muted: Bool) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.notificationsMuted = muted
        if !muted { record.mutedUntil = nil }
        applyLocally(record)
    }

    /// Silences a repository for a while; it starts speaking again on its own.
    func mute(_ id: RepoID, for duration: Duration) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.mutedUntil = Date().addingTimeInterval(Double(duration.components.seconds))
        record.notificationsMuted = false
        applyLocally(record)
        showToast("Muted \(record.name) until \(Self.untilLabel(record.mutedUntil!))", kind: .info)
    }

    func unmute(_ id: RepoID) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        record.mutedUntil = nil
        record.notificationsMuted = false
        applyLocally(record)
    }

    /// Writes a record back to the in-memory list and the engine in one step.
    private func applyLocally(_ record: RepoRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
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
        showToast(pausedUntil.map { "Checks paused until \(Self.untilLabel($0))" } ?? "Checks paused", kind: .info)
        if let duration {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.resume()
            }
        }
    }

    var pausedUntilLabel: String? {
        guard isPaused, let pausedUntil else { return nil }
        return Self.untilLabel(pausedUntil)
    }

    func resume() {
        let wasPaused = isPaused
        pauseTask?.cancel()
        pausedUntil = nil
        Task { await engine.setPaused(false) }
        if wasPaused { showToast("Checks resumed", kind: .info) }
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

    // MARK: - Watched folders

    @ObservationIgnored private var lastFolderScan: Date?

    /// Picks up clones that appeared in a watched folder. Throttled, because it runs
    /// on every panel open and touches the disk.
    func scanWatchedFolders(force: Bool = false) {
        guard !settings.watchedFolders.isEmpty else { return }
        let now = Date()
        if !force, let last = lastFolderScan, now.timeIntervalSince(last) < 300 { return }
        lastFolderScan = now
        Task { await performWatchedFolderScan() }
    }

    private func performWatchedFolderScan() async {
        var added: [String] = []
        for folder in settings.watchedFolders {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            for candidate in await engine.discoverRepositories(in: url) {
                guard !records.contains(where: { $0.path == candidate.path }) else { continue }
                // `add` refuses duplicates and non-repositories on its own; a failure here
                // just means this folder is not one we can watch.
                if let record = try? await engine.add(path: candidate) { added.append(record.name) }
            }
        }
        guard !added.isEmpty else { return }
        Log.ui.notice("watched folders added \(added.count, privacy: .public) repositories")
        showToast(added.count == 1 ? "Added \(added[0])" : "Added \(added.count) new repositories", kind: .success)
    }

    func addWatchedFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !settings.watchedFolders.contains(path) else { return }
        settings.watchedFolders.append(path)
        scanWatchedFolders(force: true)
    }

    func removeWatchedFolder(_ path: String) {
        settings.watchedFolders.removeAll { $0 == path }
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

    /// Rebuilds `openApps`. Called when the list can have changed: at launch, when the
    /// user adds or removes one, and every time the panel opens (apps come and go on disk).
    func refreshOpenApps() {
        let all = ExternalAppCatalog.installed() + settings.customOpenAppBundleIDs.compactMap(ExternalAppCatalog.customApp(bundleID:))
        // Group by kind so the panel's sections and the Settings picker agree on the order.
        openApps = ExternalApp.Kind.allCases.flatMap { kind in all.filter { $0.kind == kind } }
    }

    func defaultOpenApp() -> ExternalApp {
        openApps.first { $0.id == settings.defaultOpenAppBundleID } ?? .finder
    }

    /// What the panel offers first for one repository: the app it was last opened
    /// with, falling back to the global default while it has never been opened.
    func openApp(for id: RepoID) -> ExternalApp {
        guard let bundleID = records.first(where: { $0.id == id })?.lastOpenedAppBundleID,
              let app = openApps.first(where: { $0.id == bundleID })
        else { return defaultOpenApp() }
        return app
    }

    /// Adds an application the built-in catalog does not know about and returns it;
    /// nil when the chosen bundle has no identifier.
    @discardableResult
    func addCustomOpenApp(at url: URL) -> ExternalApp? {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        if let existing = openApps.first(where: { $0.id == bundleID }) { return existing }
        settings.customOpenAppBundleIDs.append(bundleID)
        refreshOpenApps()
        return openApps.first { $0.id == bundleID }
    }

    func removeCustomOpenApp(_ bundleID: String) {
        settings.customOpenAppBundleIDs.removeAll { $0 == bundleID }
        refreshOpenApps()
        if settings.defaultOpenAppBundleID == bundleID { settings.defaultOpenAppBundleID = ExternalApp.finder.id }
        for (index, record) in records.enumerated() where record.lastOpenedAppBundleID == bundleID {
            var updated = record
            updated.lastOpenedAppBundleID = nil
            records[index] = updated
            Task { await engine.update(updated) }
        }
    }

    func open(_ id: RepoID, in app: ExternalApp? = nil) {
        guard var record = records.first(where: { $0.id == id }) else { return }
        let target = app ?? openApp(for: id)
        if record.lastOpenedAppBundleID != target.id {
            record.lastOpenedAppBundleID = target.id
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
            Task { await engine.update(record) }
        }
        OpenInService.open(record.url, in: target)
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

    // MARK: - Previews & screenshots

    /// Replaces the live state with canned data (no engine involved).
    func installPreviewData(records: [RepoRecord], snapshots: [RepoID: RepoSnapshot], lastRefresh: Date = Date()) {
        self.records = records
        self.snapshots = snapshots
        self.checking = []
        self.lastRefresh = lastRefresh
        self.gitInstallation = GitInstallation(url: URL(fileURLWithPath: "/opt/homebrew/bin/git"), version: "2.50.1", major: 2, minor: 50, patch: 1)
        self.gitDiscoveryFinished = true
    }

    static func preview(sample: Bool = true) -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("repobar-preview-\(UUID().uuidString)")
        let model = AppModel(engine: RepoEngine(persistence: RepoPersistence(directory: directory)), settings: AppSettings(defaults: UserDefaults(suiteName: "com.aliyar.RepoBar.preview")!))
        if sample {
            let data = SampleData.make()
            model.installPreviewData(records: data.records, snapshots: data.snapshots)
        }
        return model
    }
}
