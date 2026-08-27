import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LoginItemController.self) private var loginItem

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var loginItem = loginItem
        Form {
            Section {
                Picker("Check every", selection: $settings.checkIntervalSeconds) {
                    ForEach(AppSettings.intervalChoices, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                }
                Toggle("Launch at login", isOn: $loginItem.isEnabled)
                if loginItem.requiresApproval {
                    HStack {
                        Text("Approve RepoBar in System Settings › Login Items").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { loginItem.openSystemSettings() }.controlSize(.small)
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Panel") {
                HStack {
                    Text("Open the panel with")
                    Spacer(minLength: 8)
                    if settings.panelShortcut != nil {
                        Button("Clear") { settings.panelShortcut = nil }
                            .controlSize(.small)
                    }
                    ShortcutRecorder(shortcut: $settings.panelShortcut)
                        .frame(width: 116, height: 22)
                }
                Toggle("Refresh when the panel opens", isOn: $settings.refreshOnPanelOpen)
                Toggle("Mark commits as seen when I expand a repository", isOn: $settings.markSeenOnExpand)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) hour"
    }
}
