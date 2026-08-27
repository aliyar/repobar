import AppKit
import SwiftUI
import OSLog
import GitEngine

/// Composition root. Created in `applicationWillFinishLaunching`, before any scene exists.
final class AppDependencies {
    private(set) static var shared: AppDependencies!

    let settings: AppSettings
    let hotKey = GlobalHotKey()
    let engine: RepoEngine
    let model: AppModel
    let statusItem: StatusItemController
    let notifications: NotificationManager
    let loginItem: LoginItemController
    let triggers: SystemTriggers
    let updates: UpdateController
    let panelUI = PanelUIState()
    private var observationTask: Task<Void, Never>?

    private init() {
        settings = AppSettings()
        engine = RepoEngine(settings: settings.engineSettings)
        model = AppModel(engine: engine, settings: settings)
        statusItem = StatusItemController()
        notifications = NotificationManager()
        loginItem = LoginItemController()
        triggers = SystemTriggers(model: model)
        updates = UpdateController()
        wire()
    }

    static func bootstrap() {
        guard shared == nil else { return }
        shared = AppDependencies()
    }

    private func wire() {
        let model = model
        let statusItem = statusItem
        let notifications = notifications
        let panelUI = panelUI
        let updates = updates

        statusItem.panelRoot = { [model, panelUI, updates] in
            AnyView(MenuBarPanel().environment(model).environment(panelUI).environment(updates))
        }
        statusItem.onInstallUpdate = { updates.checkForUpdates() }
        statusItem.onRefreshAll = { model.refreshAll() }
        statusItem.onMarkAllSeen = { model.markAllSeen() }
        statusItem.onTogglePause = { model.togglePause() }
        statusItem.onOpenSettings = { AppActivation.openSettings() }
        statusItem.onQuit = { NSApp.terminate(nil) }
        statusItem.onPanelOpened = {
            panelUI.selected = nil
            model.panelDidOpen()
        }
        settings.onPanelShortcutChange = { [weak self] in self?.applyPanelShortcut() }

        model.closePanel = { statusItem.closePopover() }
        model.onNotify = { record, snapshot in notifications.post(record: record, snapshot: snapshot) }
        model.onNotifyUnpushed = { record, snapshot in notifications.postUnpushed(record: record, snapshot: snapshot) }
        model.onRepositoriesAvailable = { [settings] in
            guard settings.notificationsEnabled else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                await notifications.ensureAuthorized()
            }
        }

        notifications.onShowRepository = { [panelUI] id in
            panelUI.expanded.insert(id)
            statusItem.showPopover()
        }
        notifications.onOpenRepository = { id in model.open(id) }
        notifications.onPull = { id in model.pull(id) }
        notifications.onInstallUpdate = { updates.checkForUpdates() }

        updates.onUpdateAvailable = { [settings] version in
            statusItem.updateAvailableVersion = version
            if settings.notificationsEnabled { notifications.postUpdateAvailable(version: version) }
        }
    }

    func start() {
        model.start()
        model.scanWatchedFolders(force: true)
        triggers.start()
        observeMenuBarState()
        observeAppearance()
        applyPanelShortcut()
        observeUpdateState()
        updates.start()
        Log.ui.notice("RepoBar started")
    }

    /// Mirrors "update available" into the status item menu and clears the notification when handled.
    private func observeUpdateState() {
        let version = withObservationTracking {
            updates.availableVersion
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeUpdateState() }
        }
        statusItem.updateAvailableVersion = version
        if version == nil { notifications.clearUpdateNotification() }
    }

    /// (Re-)registers the global shortcut that opens the panel.
    private func applyPanelShortcut() {
        let statusItem = statusItem
        hotKey.onPress = { statusItem.togglePopover() }
        if !hotKey.register(settings.panelShortcut), let shortcut = settings.panelShortcut {
            model.showToast("\(shortcut.displayString) is already used by another app", kind: .failure)
        }
    }

    /// Applies the user's appearance choice to the popover.
    private func observeAppearance() {
        let appearance = withObservationTracking {
            settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
        statusItem.appearance = appearance.nsAppearance
    }

    /// Re-renders the status item whenever the derived menu bar state changes.
    private func observeMenuBarState() {
        let state = withObservationTracking {
            model.menuBar
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBarState() }
        }
        statusItem.state = state
    }
}
