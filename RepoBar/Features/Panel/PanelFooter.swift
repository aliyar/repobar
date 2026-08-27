import SwiftUI

struct PanelFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.closePanel?()
                model.presentOpenPanel()
            } label: {
                Label("Add Repository…", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Add a repository or a folder of repositories (⌘O)")

            Spacer()

            if model.settings.notificationsEnabled {
                Menu {
                    if let until = model.snoozedUntilLabel {
                        Section("Silenced until \(until)") {
                            Button("Turn Notifications Back On") { model.resumeNotifications() }
                        }
                        Divider()
                    }
                    ForEach(MuteWindow.allCases, id: \.self) { window in
                        Button("Silence \(window.title)") { model.snoozeNotifications(for: window.duration()) }
                    }
                } label: {
                    Image(systemName: model.isSnoozed ? "bell.slash.circle.fill" : "bell.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.snoozedUntilLabel.map { "Notifications silenced until \($0)" } ?? "Silence notifications for a while")
            }

            Menu {
                if model.isPaused {
                    Section(model.pausedUntilLabel.map { "Paused until \($0)" } ?? "Paused") {
                        Button("Resume Checks") { model.resume() }
                    }
                    Divider()
                }
                Button("Pause for 1 hour") { model.pause(for: .seconds(3600)) }
                Button("Pause for 4 hours") { model.pause(for: .seconds(4 * 3600)) }
                Button("Pause until resumed") { model.pause(for: nil) }
            } label: {
                Image(systemName: model.isPaused ? "play.circle.fill" : "pause.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(pauseHelp)

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private var pauseHelp: String {
        guard model.isPaused else { return "Pause checks" }
        return model.pausedUntilLabel.map { "Checks paused until \($0)" } ?? "Checks paused"
    }
}
