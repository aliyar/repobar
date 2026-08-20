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
    var notificationsEnabled: Bool { didSet { set(notificationsEnabled, "notificationsEnabled") } }
    var refreshOnPanelOpen: Bool { didSet { set(refreshOnPanelOpen, "refreshOnPanelOpen") } }
    var markSeenOnExpand: Bool { didSet { set(markSeenOnExpand, "markSeenOnExpand") } }
    var defaultOpenAppBundleID: String { didSet { set(defaultOpenAppBundleID, "defaultOpenAppBundleID") } }
    var menuBarStyle: MenuBarStyle { didSet { set(menuBarStyle.rawValue, "menuBarStyle") } }
    var showIdleDots: Bool { didSet { set(showIdleDots, "showIdleDots") } }
    var idleDotStyle: IdleDotStyle { didSet { set(idleDotStyle.rawValue, "idleDotStyle") } }
    var badgeMode: BadgeMode { didSet { set(badgeMode.rawValue, "badgeMode") } }

    /// Called after any engine-relevant setting changes.
    @ObservationIgnored var onEngineSettingsChange: (() -> Void)?

    static let intervalChoices = [60, 120, 300, 600, 900, 1800, 3600]
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
        refreshOnPanelOpen = defaults.object(forKey: "refreshOnPanelOpen") as? Bool ?? true
        markSeenOnExpand = defaults.object(forKey: "markSeenOnExpand") as? Bool ?? false
        defaultOpenAppBundleID = defaults.string(forKey: "defaultOpenAppBundleID") ?? ExternalApp.finder.id
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .dots
        showIdleDots = defaults.object(forKey: "showIdleDots") as? Bool ?? true
        idleDotStyle = IdleDotStyle(rawValue: defaults.string(forKey: "idleDotStyle") ?? "") ?? .faded
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
        return settings
    }

    private func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func engineChanged() {
        onEngineSettingsChange?()
    }
}
