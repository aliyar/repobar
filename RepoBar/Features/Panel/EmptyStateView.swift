import SwiftUI

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                Text("No repositories yet").font(.headline)
                Text("Drop a folder here or").font(.caption).foregroundStyle(.secondary)
            }
            Button("Add Repository…") {
                model.closePanel?()
                model.presentOpenPanel()
            }
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(10)
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}
