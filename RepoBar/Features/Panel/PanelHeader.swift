import SwiftUI

struct PanelHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateController.self) private var updates
    @Environment(\.openSettings) private var openSettings

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

    private var headerRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.gitMissing ? .red : .secondary)
                    .lineLimit(1)
                if let lastRefresh = model.lastRefresh, !model.isRefreshing, !model.records.isEmpty {
                    RelativeTimeText(date: lastRefresh, prefix: "Updated ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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

            SettingsLink {
                Image(systemName: "gearshape").frame(width: 16, height: 16)
            }
            .simultaneousGesture(TapGesture().onEnded {
                model.closePanel?()
                AppActivation.bringSettingsToFront()
            })
            .help("Settings (⌘,)")

            // ⌘, from inside the panel.
            Button("") {
                model.closePanel?()
                openSettings()
                AppActivation.bringSettingsToFront()
            }
            .keyboardShortcut(",", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
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
