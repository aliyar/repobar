import SwiftUI
import ServiceManagement
import UserNotifications

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LoginItemController.self) private var loginItem
    @Environment(NotificationManager.self) private var notifications

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
                Toggle("Notify me about new commits", isOn: $settings.notificationsEnabled)
                    .onChange(of: settings.notificationsEnabled) { _, enabled in
                        if enabled { Task { await notifications.ensureAuthorized() } }
                    }
                if settings.notificationsEnabled && notifications.authorizationStatus == .denied {
                    HStack {
                        Text("Notifications are disabled for RepoBar in System Settings.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }.controlSize(.small)
                    }
                }
                Picker("Open repositories in", selection: $settings.defaultOpenAppBundleID) {
                    ForEach(ExternalAppCatalog.installed()) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = OpenInService.icon(for: app) { Image(nsImage: icon) }
                        }
                        .tag(app.id)
                    }
                }
            }

            Section("Menu Bar") {
                MenuBarPreview(state: model.menuBar)
                Picker("Style", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.menuBarStyle == .dots {
                    Toggle("Show idle repositories as dim dots", isOn: $settings.showIdleDots)
                    if settings.showIdleDots {
                        Picker("Idle dot style", selection: $settings.idleDotStyle) {
                            ForEach(IdleDotStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    Text("Up to \(StatusItemLayout.maxFullDots) repositories are shown as dots; with more, only the ones with new commits appear.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.menuBarStyle == .count {
                    Picker("Count shows", selection: $settings.badgeMode) {
                        ForEach(BadgeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }

            Section("Panel") {
                Toggle("Refresh when the panel opens", isOn: $settings.refreshOnPanelOpen)
                Toggle("Mark commits as seen when I expand a repository", isOn: $settings.markSeenOnExpand)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            loginItem.refresh()
            notifications.refreshAuthorizationStatus()
        }
    }

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 3600 ? "\(seconds / 60) min" : "\(seconds / 3600) hour"
    }
}

/// Live preview of the status item on a light and a dark menu bar.
struct MenuBarPreview: View {
    let state: MenuBarState

    var body: some View {
        let layout = StatusItemLayout.make(from: state.repos.isEmpty ? .sample : state)
        HStack(spacing: 12) {
            StatusItemView(layout: layout, foreground: .black.opacity(0.88))
                .environment(\.colorScheme, .light)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 6))
            StatusItemView(layout: layout, foreground: .white.opacity(0.92))
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 6))
            Spacer()
            if state.repos.isEmpty {
                Text("Sample").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(Text("Menu bar preview: \(state.summary)"))
    }
}
