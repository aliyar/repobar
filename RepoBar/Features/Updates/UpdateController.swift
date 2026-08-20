import AppKit
import Observation
import OSLog
import Sparkle

/// Sparkle-based auto-update. Scheduled checks use Sparkle's "gentle reminders": instead of a window
/// stealing focus, the panel/menu show an "Update available" hint and a notification is posted;
/// user-initiated checks (About → Check for Updates…) always show Sparkle's standard UI.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// User-defaults key that overrides the appcast URL (for testing against a local feed).
    nonisolated static let feedOverrideKey = "UpdateFeedURL"

    private(set) var availableVersion: String?
    private(set) var canCheckForUpdates = false
    private(set) var lastCheckDate: Date?
    private(set) var isStarted = false

    /// Fired when a scheduled check found an update and the app is not in focus.
    @ObservationIgnored var onUpdateAvailable: ((String) -> Void)?
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Starts Sparkle (never in tests). Safe to call once.
    func start() {
        guard !isStarted, !ProcessInfo.processInfo.isRunningTests else { return }
        isStarted = true
        controller.startUpdater()
        observations.append(updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = value }
        })
        observations.append(updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? nil
            Task { @MainActor in self?.lastCheckDate = value }
        })
        Log.ui.notice("updater started; feed=\(self.updater.feedURL?.absoluteString ?? "-", privacy: .public)")
    }

    /// Shows Sparkle's UI (also brings an already-found update into focus).
    func checkForUpdates() {
        guard isStarted else { return }
        AppActivation.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: UpdateController.feedOverrideKey)
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // A menu bar app should never pop a window on its own: scheduled updates are announced with
        // the panel banner, the status-item menu and a notification; the user brings up Sparkle's UI.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            availableVersion = version
            onUpdateAvailable?(version)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
