import Foundation
import Observation
import GitEngine

/// User preferences backed by `UserDefaults`. Observable so views update live.
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var checkIntervalSeconds: Int { didSet { set(checkIntervalSeconds, "checkIntervalSeconds"); engineChanged() } }
    var maxConcurrentChecks: Int { didSet { set(maxConcurrentChecks, "maxConcurrentChecks"); engineChanged() } }
    var fetchTimeoutSeconds: Int { didSet { set(fetchTimeoutSeconds, "fetchTimeoutSeconds"); engineChanged() } }
    var probeBeforeFetch: Bool { didSet { set(probeBeforeFetch, "probeBeforeFetch"); engineChanged() } }
    var pruneOnFetch: Bool { didSet { set(pruneOnFetch, "pruneOnFetch"); engineChanged() } }
    var gitPathOverride: String { didSet { set(gitPathOverride, "gitPathOverride"); engineChanged() } }
    var extraPaths: String { didSet { set(extraPaths, "extraPaths"); engineChanged() } }
    var notificationsEnabled: Bool { didSet { set(notificationsEnabled, "notificationsEnabled"); engineChanged() } }
    /// Every repository stays quiet until this date; nil means notifications are live.
    var notificationsSnoozedUntil: Date? {
        didSet { set(notificationsSnoozedUntil, "notificationsSnoozedUntil"); engineChanged() }
    }
    var unpushedReminderEnabled: Bool { didSet { set(unpushedReminderEnabled, "unpushedReminderEnabled"); engineChanged() } }
    var unpushedReminderHours: Int { didSet { set(unpushedReminderHours, "unpushedReminderHours"); engineChanged() } }
    var refreshOnPanelOpen: Bool { didSet { set(refreshOnPanelOpen, "refreshOnPanelOpen") } }
    /// Folders scanned for clones that are not on the list yet.
    var watchedFolders: [String] { didSet { set(watchedFolders, "watchedFolders") } }
    var markSeenOnExpand: Bool { didSet { set(markSeenOnExpand, "markSeenOnExpand") } }
    var defaultOpenAppBundleID: String { didSet { set(defaultOpenAppBundleID, "defaultOpenAppBundleID") } }
    var customOpenAppBundleIDs: [String] { didSet { set(customOpenAppBundleIDs, "customOpenAppBundleIDs") } }
    var appearance: AppAppearance { didSet { set(appearance.rawValue, "appearance") } }
    /// Global shortcut that opens the panel; nil when none is set.
    var panelShortcut: GlobalHotKey.Shortcut? {
        didSet {
            set(panelShortcut.map { Int($0.keyCode) } ?? -1, "panelShortcutKeyCode")
            set(panelShortcut.map { Int($0.modifiers) } ?? 0, "panelShortcutModifiers")
            onPanelShortcutChange?()
        }
    }
    var menuBarStyle: MenuBarStyle { didSet { set(menuBarStyle.rawValue, "menuBarStyle") } }
    var showIdleDots: Bool { didSet { set(showIdleDots, "showIdleDots") } }
    var idleDotStyle: IdleDotStyle { didSet { set(idleDotStyle.rawValue, "idleDotStyle") } }
    var badgeMode: BadgeMode { didSet { set(badgeMode.rawValue, "badgeMode") } }

    /// Called after any engine-relevant setting changes.
    @ObservationIgnored var onEngineSettingsChange: (() -> Void)?
    /// Called when the global shortcut changes, so it can be re-registered.
    @ObservationIgnored var onPanelShortcutChange: (() -> Void)?

    static let intervalChoices = [60, 120, 300, 600, 900, 1800, 3600]
    static let unpushedReminderChoices = [4, 8, 24, 72]
    static let fetchTimeoutChoices = [30, 60, 90, 120]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checkIntervalSeconds = defaults.object(forKey: "checkIntervalSeconds") as? Int ?? 300
        maxConcurrentChecks = defaults.object(forKey: "maxConcurrentChecks") as? Int ?? 4
        fetchTimeoutSeconds = defaults.object(forKey: "fetchTimeoutSeconds") as? Int ?? 90
        probeBeforeFetch = defaults.object(forKey: "probeBeforeFetch") as? Bool ?? true
        pruneOnFetch = defaults.object(forKey: "pruneOnFetch") as? Bool ?? false
        gitPathOverride = defaults.string(forKey: "gitPathOverride") ?? ""
        extraPaths = defaults.string(forKey: "extraPaths") ?? ""
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        notificationsSnoozedUntil = defaults.object(forKey: "notificationsSnoozedUntil") as? Date
        unpushedReminderEnabled = defaults.object(forKey: "unpushedReminderEnabled") as? Bool ?? true
        unpushedReminderHours = defaults.object(forKey: "unpushedReminderHours") as? Int ?? 24
        refreshOnPanelOpen = defaults.object(forKey: "refreshOnPanelOpen") as? Bool ?? true
        watchedFolders = defaults.stringArray(forKey: "watchedFolders") ?? []
        markSeenOnExpand = defaults.object(forKey: "markSeenOnExpand") as? Bool ?? false
        defaultOpenAppBundleID = defaults.string(forKey: "defaultOpenAppBundleID") ?? ExternalApp.finder.id
        customOpenAppBundleIDs = defaults.stringArray(forKey: "customOpenAppBundleIDs") ?? []
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        // No stored value at all means a fresh install: start with the suggested
        // shortcut. Clearing it writes -1, which is remembered as "none".
        if let storedKeyCode = defaults.object(forKey: "panelShortcutKeyCode") as? Int {
            panelShortcut = storedKeyCode >= 0
                ? GlobalHotKey.Shortcut(keyCode: UInt32(storedKeyCode), modifiers: UInt(defaults.integer(forKey: "panelShortcutModifiers")))
                : nil
        } else {
            panelShortcut = .suggested
        }
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .dots
        showIdleDots = defaults.object(forKey: "showIdleDots") as? Bool ?? true
        idleDotStyle = IdleDotStyle(rawValue: defaults.string(forKey: "idleDotStyle") ?? "") ?? .ring
        badgeMode = BadgeMode(rawValue: defaults.string(forKey: "badgeMode") ?? "") ?? .repositories
    }

    var engineSettings: EngineSettings {
        var settings = EngineSettings()
        settings.checkInterval = .seconds(max(60, checkIntervalSeconds))
        settings.maxConcurrentChecks = min(8, max(1, maxConcurrentChecks))
        settings.fetchTimeout = .seconds(max(15, fetchTimeoutSeconds))
        settings.probeBeforeFetch = probeBeforeFetch
        settings.pruneOnFetch = pruneOnFetch
        let override = gitPathOverride.trimmingCharacters(in: .whitespaces)
        settings.gitPathOverride = override.isEmpty ? nil : override
        settings.extraPaths = extraPaths.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        settings.notificationsSnoozedUntil = notificationsSnoozedUntil
        settings.unpushedReminderAfter = unpushedReminderEnabled && notificationsEnabled
            ? .seconds(max(1, unpushedReminderHours) * 3600)
            : nil
        return settings
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func engineChanged() {
        onEngineSettingsChange?()
    }
}
