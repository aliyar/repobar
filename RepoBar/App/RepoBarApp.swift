import SwiftUI

@main
struct RepoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `body` is evaluated before the app delegate's launch callbacks run.
        AppDependencies.bootstrap()
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(AppDependencies.shared.model)
                .environment(AppDependencies.shared.loginItem)
                .environment(AppDependencies.shared.notifications)
                .environment(AppDependencies.shared.updates)
        }
        .windowResizability(.contentSize)
    }
}
