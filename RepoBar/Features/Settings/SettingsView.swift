import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
        // Read here rather than in the Settings scene so the window follows the
        // choice the moment it changes.
        .preferredColorScheme(model.settings.appearance.colorScheme)
        .onAppear { AppActivation.bringSettingsToFront() }
    }
}
