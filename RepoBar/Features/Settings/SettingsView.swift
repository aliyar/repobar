import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            RepositorySettingsView()
                .tabItem { Label("Repositories", systemImage: "folder") }
            MenuBarSettingsView()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640)
        // Read here rather than in the Settings scene so the window follows the
        // choice the moment it changes.
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onAppear { AppActivation.bringSettingsToFront() }
    }
}
