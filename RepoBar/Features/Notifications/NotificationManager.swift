import AppKit
import Observation
import OSLog
import UserNotifications
import GitEngine

/// Posts "new commits" notifications and routes their actions.
@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String { case open = "OPEN", pull = "PULL", install = "INSTALL" }
    static let category = "REPO_UPDATE"
    static let updateCategory = "APP_UPDATE"

    /// Open the panel for a repository (default click).
    @ObservationIgnored var onShowRepository: ((RepoID) -> Void)?
    /// "Open" action: open the repository in the default app.
    @ObservationIgnored var onOpenRepository: ((RepoID) -> Void)?
    /// "Pull" action.
    @ObservationIgnored var onPull: ((RepoID) -> Void)?
    /// App-update notification clicked.
    @ObservationIgnored var onInstallUpdate: (() -> Void)?

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
    }

    func configure() {
        guard let center else { return }
        center.delegate = self
        let open = UNNotificationAction(identifier: Action.open.rawValue, title: "Open", options: [.foreground])
        let pull = UNNotificationAction(identifier: Action.pull.rawValue, title: "Pull", options: [])
        let install = UNNotificationAction(identifier: Action.install.rawValue, title: "Install", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [open, pull], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.updateCategory, actions: [install], intentIdentifiers: []),
        ])
        refreshAuthorizationStatus()
    }

    func refreshAuthorizationStatus() {
        guard let center else { return }
        Task { @MainActor in
            let settings = await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus
        }
    }

    /// Requests permission if it was never asked. Returns whether notifications are allowed.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            refreshAuthorizationStatus()
            return granted
        case .authorized, .provisional:
            authorizationStatus = settings.authorizationStatus
            return true
        default:
            authorizationStatus = settings.authorizationStatus
            return false
        }
    }

    func post(record: RepoRecord, snapshot: RepoSnapshot) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = record.name
        let count = snapshot.unseenCount
        let branch = snapshot.watched?.key ?? "remote"
        content.subtitle = "\(count) new \(count == 1 ? "commit" : "commits") on \(branch)"
        if let first = snapshot.incoming.first(where: \.isNew) ?? snapshot.incoming.first {
            content.body = "\(first.subject) — \(first.authorName)"
        }
        content.categoryIdentifier = Self.category
        content.threadIdentifier = record.id.uuidString
        content.userInfo = ["repoID": record.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "repo.\(record.id.uuidString)", content: content, trigger: nil)
        center.add(request) { error in
            if let error { Log.notifications.error("notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func postUpdateAvailable(version: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "RepoBar \(version) is available"
        content.body = "Click to see what's new and install the update."
        content.categoryIdentifier = Self.updateCategory
        content.threadIdentifier = "app-update"
        content.userInfo = ["update": version]
        center.add(UNNotificationRequest(identifier: "app-update", content: content, trigger: nil)) { error in
            if let error { Log.notifications.error("update notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func clearUpdateNotification() {
        center?.removeDeliveredNotifications(withIdentifiers: ["app-update"])
    }

    func clear(for id: RepoID) {
        center?.removeDeliveredNotifications(withIdentifiers: ["repo.\(id.uuidString)"])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let repoID = (userInfo["repoID"] as? String).flatMap(UUID.init(uuidString:))
        let isUpdate = userInfo["update"] != nil
        let action = response.actionIdentifier
        await MainActor.run {
            if isUpdate {
                onInstallUpdate?()
                return
            }
            guard let repoID else { return }
            switch action {
            case Action.open.rawValue: onOpenRepository?(repoID)
            case Action.pull.rawValue: onPull?(repoID)
            default: onShowRepository?(repoID)
            }
        }
    }
}
