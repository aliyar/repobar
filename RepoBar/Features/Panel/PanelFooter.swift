import SwiftUI

struct PanelFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

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

            SettingsLink {
                Text("Settings")
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

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

}
