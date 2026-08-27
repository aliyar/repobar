import SwiftUI

struct AboutView: View {
    @Environment(UpdateController.self) private var updates

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        @Bindable var updates = updates
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 3) {
                Text("RepoBar").font(.title2.weight(.semibold))
                Text("Version \(updates.currentVersion) (\(build))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Keeps an eye on your local git repositories and tells you when the remote has new commits.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 320)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let version = updates.availableVersion {
                        HStack {
                            Label("RepoBar \(version) is available", systemImage: "sparkles")
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            Button("Install…") { updates.checkForUpdates() }
                                .keyboardShortcut(.defaultAction)
                        }
                    } else {
                        HStack {
                            Button("Check for Updates…") { updates.checkForUpdates() }
                                .disabled(!updates.canCheckForUpdates)
                            Spacer()
                            if let date = updates.lastCheckDate {
                                RelativeTimeText(date: date, prefix: "Last checked ")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                        .font(.callout)
                }
                .padding(4)
            }
            .frame(maxWidth: 360)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://repobar.greatpixels.com")!)
                Link("GitHub", destination: URL(string: "https://github.com/aliyar/repobar")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/aliyar/repobar/issues")!)
            }
            .font(.callout)
            Text("Tip: right-click the menu bar icon for quick actions.")
                .font(.caption2).foregroundStyle(.tertiary)
            Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}
