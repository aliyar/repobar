import SwiftUI
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(NotificationManager.self) private var notifications

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
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

            if settings.notificationsEnabled {
                Section("Unpushed Commits") {
                    Toggle("Remind me about unpushed commits", isOn: $settings.unpushedReminderEnabled)
                    if settings.unpushedReminderEnabled {
                        Picker("After", selection: $settings.unpushedReminderHours) {
                            ForEach(AppSettings.unpushedReminderChoices, id: \.self) { hours in
                                Text(Self.hoursLabel(hours)).tag(hours)
                            }
                        }
                        Text("Repeats at most once a day while the branch stays ahead. RepoBar never pushes for you.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Silence") {
                    if let until = model.snoozedUntilLabel {
                        HStack {
                            Image(systemName: "bell.slash.fill").foregroundStyle(.secondary)
                            Text("Silenced until \(until)")
                            Spacer()
                            Button("Turn Back On") { model.resumeNotifications() }.controlSize(.small)
                        }
                    } else {
                        HStack {
                            Text("Silence every repository for a while.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu("Silence…") {
                                ForEach(MuteWindow.allCases, id: \.self) { window in
                                    Button(window.title.capitalizedFirst) { model.snoozeNotifications(for: window.duration()) }
                                }
                            }
                            .fixedSize()
                            .controlSize(.small)
                        }
                    }
                    Text("A single repository can be muted from its row in the panel.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { notifications.refreshAuthorizationStatus() }
    }

    static func hoursLabel(_ hours: Int) -> String {
        hours < 24 ? "\(hours) hours" : "\(hours / 24) day\(hours == 24 ? "" : "s")"
    }
}

extension String {
    /// "for 1 hour" → "For 1 hour", for menu items built from a lowercase phrase.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
