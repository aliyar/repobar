import SwiftUI

struct MenuBarSettingsView: View {
    @Environment(AppModel.self) private var model

    /// Says what the limit means for this Mac, not in the abstract: with more
    /// repositories than dots, only the ones worth looking at are drawn.
    static func limitExplanation(max: Int, repositories: Int) -> String {
        guard repositories > max else {
            return "All \(repositories == 0 ? "your" : "\(repositories)") repositories fit, so every one of them gets a dot."
        }
        return "You have \(repositories) repositories: the \(max) that need you most get a dot, and the remaining \(repositories - max) are counted after them."
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                MenuBarPreview(state: model.menuBar)
                Picker("Style", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if settings.menuBarStyle == .dots {
                Section("Dots") {
                    Toggle("Show idle repositories", isOn: $settings.showIdleDots)
                    if settings.showIdleDots {
                        Picker("Idle dot style", selection: $settings.idleDotStyle) {
                            ForEach(IdleDotStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                    }
                    HStack {
                        Text("Show at most")
                        Spacer(minLength: 8)
                        TextField("", value: $settings.maxMenuBarDots, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 46)
                        Stepper("", value: $settings.maxMenuBarDots, in: StatusItemLayout.maxDotsRange)
                            .labelsHidden()
                        Text("dots").foregroundStyle(.secondary)
                    }
                    Text(Self.limitExplanation(max: settings.maxMenuBarDots, repositories: model.records.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if settings.menuBarStyle == .count {
                Section("Count") {
                    Picker("Count shows", selection: $settings.badgeMode) {
                        ForEach(BadgeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Live preview of the status item on a light and a dark menu bar.
struct MenuBarPreview: View {
    let state: MenuBarState

    var body: some View {
        // Always a fixed, made-up scenario rather than the real repositories: the point
        // is to show what a style looks like, and the real state is usually quiet —
        // Count would render an empty menu bar exactly when you are choosing it.
        let layout = StatusItemLayout.make(from: MenuBarState.sample(styledLike: state))
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
            Text("Sample").font(.caption2).foregroundStyle(.tertiary)
        }
        .accessibilityLabel(Text("Menu bar preview of the \(state.style.displayName) style"))
    }
}
