import SwiftUI

struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updates

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if let version = updates.availableVersion {
                UpdateBanner(version: version) {
                    model.closePanel?()
                    updates.checkForUpdates()
                }
            }
        }
    }

    private var statusText: some View {
        Text(model.statusLine)
            .font(.caption.weight(.medium))
            .foregroundStyle(model.gitMissing ? .red : .secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var showsTimestamp: Bool {
        model.lastRefresh != nil && !model.isRefreshing && !model.records.isEmpty
    }

    private var pauseHelp: String {
        guard model.isPaused else { return "Pause checks" }
        return model.pausedUntilLabel.map { "Checks paused until \($0)" } ?? "Checks paused"
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            // One line: the second one cost 17pt of header for "Updated just now", which
            // says nothing most of the time. The timestamp still rides along when the
            // status is short enough to leave room for it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    statusText
                    if showsTimestamp {
                        Text("·").font(.caption2).foregroundStyle(.quaternary)
                        RelativeTimeText(date: model.lastRefresh!, prefix: "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                statusText
            }
            Spacer(minLength: 4)
            Button {
                model.refreshAll()
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh all (⌘R)")
            .disabled(model.records.isEmpty)

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
                    .frame(width: 16, height: 16)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(pauseHelp)

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
                        .frame(width: 16, height: 16)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(model.snoozedUntilLabel.map { "Notifications silenced until \($0)" } ?? "Silence notifications for a while")
            }

        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 36)
    }
}

struct UpdateBanner: View {
    let version: String
    let install: () -> Void

    var body: some View {
        Button(action: install) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("RepoBar \(version) is available")
                Spacer()
                Text("Install…").fontWeight(.semibold)
            }
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.accentColor.opacity(0.08))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("RepoBar \(version) is available, install"))
    }
}
