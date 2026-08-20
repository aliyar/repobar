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

            if model.isPaused {
                Button("Resume") { model.resume() }
                    .help("Resume checks")
            } else {
                Menu {
                    Button("Pause for 1 hour") { model.pause(for: .seconds(3600)) }
                    Button("Pause for 4 hours") { model.pause(for: .seconds(4 * 3600)) }
                    Button("Pause until resumed") { model.pause(for: nil) }
                } label: {
                    Image(systemName: "pause.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pause checks")
            }

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
