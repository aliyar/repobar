import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LoginItemController.self) private var loginItem
    @Environment(NotificationManager.self) private var notifications
    @State private var addApplicationError: String?

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
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
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
            }

            Section("Open In") {
                Picker("Default application", selection: $settings.defaultOpenAppBundleID) {
                    ForEach(model.openApps) { app in
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = OpenInService.icon(for: app) { Image(nsImage: icon) }
                        }
                        .tag(app.id)
                    }
                }
                Text("Used for repositories you have not opened yet; afterwards each repository remembers the app you last opened it with.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.openApps.filter { $0.kind == .custom }) { app in
                    HStack {
                        if let icon = OpenInService.icon(for: app) { Image(nsImage: icon) }
                        Text(app.name)
                        Spacer()
                        Button("Remove") { model.removeCustomOpenApp(app.id) }.controlSize(.small)
                    }
                }
                HStack {
                    if let error = addApplicationError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else {
                        Text("Any application that is not in the list.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add Application…") { chooseApplication() }.controlSize(.small)
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

    /// Lets the user point at any application the built-in catalog does not list.
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an application to open repositories in"
        panel.prompt = "Add"
        AppActivation.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let app = model.addCustomOpenApp(at: url) else {
            addApplicationError = "\(url.deletingPathExtension().lastPathComponent) has no bundle identifier"
            return
        }
        addApplicationError = nil
        model.settings.defaultOpenAppBundleID = app.id
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
